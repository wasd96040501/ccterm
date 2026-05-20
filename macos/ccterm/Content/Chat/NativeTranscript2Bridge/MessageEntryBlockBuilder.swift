import AgentSDK
import AppKit
import Foundation

/// `MessageEntry` → `[Block]` translation. Pure function, safe on any thread.
///
/// Design notes:
/// - **Stable ids**: every Block / ToolGroupBlock.Child UUID is derived from
///   `(entryId, role, idx...)` via `StableBlockID`. The same entry across state
///   transitions (`.localUser` → `.remote.user`, tool_result back-fill, group
///   items growing) yields the same id, so the Coordinator's `.update` path
///   swaps kind in place and preserves row-local state (fold, selection,
///   animation).
/// - **Text vs tool ordering inside an assistant entry**: follows the original
///   `Message2Assistant.message?.content` order. Consecutive text blocks buffer
///   into one markdown chunk; on tool_use the markdown chunk is flushed first,
///   then a single-child toolGroup is emitted, then iteration continues.
/// - **GroupEntry**: tool_uses across multiple items aggregate into one
///   toolGroup, with `completedTitle` as the header.
///
/// `unknown` / `thinking` blocks are skipped and produce no Block.
enum MessageEntryBlockBuilder {

    /// Batch entry point. Used by `setHistory` (reset). Internally walks each
    /// entry through `entryBlocks` once and merges — guaranteeing that the
    /// blocks for one entry are identical between batch and incremental paths
    /// (no merge-only side computations).
    static func blocks(from entries: [MessageEntry]) -> [Block] {
        var out: [Block] = []
        for entry in entries { out.append(contentsOf: entryBlocks(entry)) }
        return out
    }

    /// Bulk precompute path. Builds blocks for every entry and returns a
    /// `entry.id → [Block]` map suitable for `MessagesChange.reset` /
    /// `.prepended`'s `precomputedBlocks` payload. Pure and safe to call
    /// off the main actor — `MarkdownDocument(parsing:)` (the dominant
    /// cost) is invoked here, never inside the bridge's main-thread
    /// dispatch arm. Returns an empty map when `entries` is empty.
    static func precompute(_ entries: [MessageEntry]) -> [UUID: [Block]] {
        var out: [UUID: [Block]] = [:]
        out.reserveCapacity(entries.count)
        for entry in entries {
            out[entry.id] = entryBlocks(entry)
        }
        return out
    }

    /// Single entry → 0..N blocks. The bridge's incremental paths (append /
    /// prepend / mutate) call this directly to translate an entry into the
    /// exact Block list handed to the controller.
    static func entryBlocks(_ entry: MessageEntry) -> [Block] {
        switch entry {
        case .single(let s):
            return singleBlocks(s)
        case .group(let g):
            return makeGroupBlock(g).map { [$0] } ?? []
        }
    }

    // MARK: - Single

    private static func singleBlocks(_ single: SingleEntry) -> [Block] {
        switch single.payload {
        case .localUser(let local):
            return localUserBlocks(local, single: single)

        case .remote(let m):
            switch m {
            case .user(let u): return remoteUserBlocks(u, single: single)
            case .assistant(let a): return assistantBlocks(a, single: single)
            default: return []
            }
        }
    }

    private static func localUserBlocks(
        _ local: LocalUserInput,
        single: SingleEntry
    ) -> [Block] {
        var out: [Block] = []
        let images = local.images.compactMap { (data, _) -> NSImage? in
            NSImage(data: data)
        }
        if !images.isEmpty {
            out.append(
                Block(
                    id: userAttachmentsBlockId(entryId: single.id),
                    kind: .userAttachments(images: images)))
        }
        if let text = local.text, !text.isEmpty {
            out.append(
                Block(
                    id: userBubbleBlockId(entryId: single.id),
                    kind: .userBubble(text: text)))
        }
        return out
    }

    private static func remoteUserBlocks(
        _ user: Message2User,
        single: SingleEntry
    ) -> [Block] {
        guard let content = user.message?.content else { return [] }
        var images: [NSImage] = []
        let text: String
        switch content {
        case .string(let s):
            text = s
        case .array(let items):
            // Walk the content array once: text items concatenate into the
            // bubble caption; image items decode their base64 data into
            // NSImage for the attachments strip. tool_result items are
            // dropped — they're already merged into the matching
            // assistant's toolGroup.
            var texts: [String] = []
            for item in items {
                switch item {
                case .text(let t):
                    if let s = t.text, !s.isEmpty { texts.append(s) }
                case .image(let img):
                    guard let source = img.source,
                        source.type == "base64",
                        let b64 = source.data,
                        let data = Data(base64Encoded: b64),
                        let ns = NSImage(data: data)
                    else { continue }
                    images.append(ns)
                case .toolResult, .unknown:
                    continue
                }
            }
            text = texts.joined(separator: "\n\n")
        case .other:
            return []
        }
        var out: [Block] = []
        if !images.isEmpty {
            out.append(
                Block(
                    id: userAttachmentsBlockId(entryId: single.id),
                    kind: .userAttachments(images: images)))
        }
        if !text.isEmpty {
            out.append(
                Block(
                    id: userBubbleBlockId(entryId: single.id),
                    kind: .userBubble(text: text)))
        }
        return out
    }

    /// The user bubble block id must stay constant across the
    /// `.localUser → .remote.user` transition: `confirm` goes through
    /// `.update(id, newKind)`. A changed id degrades to remove + insert and
    /// wipes animation / selection.
    private static func userBubbleBlockId(entryId: UUID) -> UUID {
        StableBlockID.derive("entry", entryId.uuidString, "userBubble")
    }

    /// Sibling stable id for the attachments strip — same survival
    /// contract as the bubble id across the `.localUser → .remote.user`
    /// transition. Distinct slug so both blocks coexist for one entry.
    private static func userAttachmentsBlockId(entryId: UUID) -> UUID {
        StableBlockID.derive("entry", entryId.uuidString, "userAttachments")
    }

    private static func assistantBlocks(
        _ assistant: Message2Assistant,
        single: SingleEntry
    ) -> [Block] {
        guard let blocks = assistant.message?.content else { return [] }

        var out: [Block] = []
        var textBuffer: [String] = []
        var textStartIdx: Int = 0

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            let source = textBuffer.joined(separator: "\n\n")
            textBuffer.removeAll(keepingCapacity: true)
            let prefix = "entry|\(single.id.uuidString)|md\(textStartIdx)"
            out.append(contentsOf: MarkdownToBlocks.blocks(source: source, idPrefix: prefix))
        }

        for (idx, block) in blocks.enumerated() {
            switch block {
            case .text(let t):
                if let s = t.text, !s.isEmpty {
                    if textBuffer.isEmpty { textStartIdx = idx }
                    textBuffer.append(s)
                }
            case .toolUse(let tu):
                flushText()
                // ToolUse.id is Optional<String> — upstream CLI populates it
                // for every tool_use; nil only appears in dirty data. Fallback
                // `tu|<idx>` keeps child id derivation stable; result lookup
                // with nil simply misses.
                let toolUseId = tu.id ?? "tu|\(single.id.uuidString)|\(idx)"
                let result = tu.id.flatMap { single.toolResults[$0] }
                let child = ToolUseToChild.make(
                    toolUse: tu,
                    toolUseId: toolUseId,
                    result: result)
                // Single-tool group: all three title states derive from the
                // same tu. With one tool, "aggregated progressive" degrades
                // to "per-tool progressive"; introducing `activeCountPhrase(1)`
                // would replace "Reading foo.swift" with the vaguer
                // "Reading 1 file".
                let activeTitle = tu.activeFragment ?? tu.caseName
                let completedTitle = tu.completedFragment ?? tu.caseName
                let group = ToolGroupBlock(
                    activeTitle: activeTitle,
                    expandedActiveTitle: activeTitle,
                    completedTitle: completedTitle,
                    children: [child])
                let blockId = StableBlockID.derive(
                    "entry", single.id.uuidString, "tg", String(idx))
                out.append(Block(id: blockId, kind: .toolGroup(group)))
            case .thinking, .unknown:
                continue
            }
        }
        flushText()
        return out
    }

    // MARK: - Group

    private static func makeGroupBlock(_ group: GroupEntry) -> Block? {
        var children: [ToolGroupBlock.Child] = []
        for (itemIdx, item) in group.items.enumerated() {
            guard case .remote(let m) = item.payload,
                case .assistant(let a) = m,
                let blocks = a.message?.content
            else { continue }
            for (blockIdx, block) in blocks.enumerated() {
                guard case .toolUse(let tu) = block else { continue }
                let toolUseId =
                    tu.id
                    ?? "tu|\(group.id.uuidString)|\(itemIdx)|\(blockIdx)"
                let result = tu.id.flatMap { item.toolResults[$0] }
                children.append(
                    ToolUseToChild.make(
                        toolUse: tu,
                        toolUseId: toolUseId,
                        result: result))
            }
        }
        guard !children.isEmpty else { return nil }
        // Reuse the three title states already implemented on
        // Session's `GroupEntry`: `activeTitle` (last child
        // progressive), `expandedActiveTitle` (aggregated progressive),
        // `completedTitle` (aggregated past tense). Bridge just packages —
        // it doesn't re-implement aggregation.
        return Block(
            id: StableBlockID.derive("group", group.id.uuidString),
            kind: .toolGroup(
                ToolGroupBlock(
                    activeTitle: group.activeTitle,
                    expandedActiveTitle: group.expandedActiveTitle,
                    completedTitle: group.completedTitle,
                    children: children)))
    }
}

import AgentSDK
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

    /// Batch entry point. Used by `loadInitial` (reset). Internally walks each
    /// entry through `entryBlocks` once and merges — guaranteeing that the
    /// blocks for one entry are identical between batch and incremental paths
    /// (no merge-only side computations).
    static func blocks(from entries: [MessageEntry]) -> [Block] {
        var out: [Block] = []
        for entry in entries { out.append(contentsOf: entryBlocks(entry)) }
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
            guard let text = local.text, !text.isEmpty else { return [] }
            return [
                Block(
                    id: userBubbleBlockId(entryId: single.id),
                    kind: .userBubble(text: text))
            ]

        case .remote(let m):
            switch m {
            case .user(let u): return remoteUserBlocks(u, single: single)
            case .assistant(let a): return assistantBlocks(a, single: single)
            default: return []
            }
        }
    }

    private static func remoteUserBlocks(
        _ user: Message2User,
        single: SingleEntry
    ) -> [Block] {
        guard let content = user.message?.content else { return [] }
        let text: String
        switch content {
        case .string(let s):
            text = s
        case .array(let items):
            // Drop tool_result items (already merged into the matching
            // assistant's toolGroup); join remaining text items into one
            // userBubble.
            text = items.compactMap { item -> String? in
                if case .text(let t) = item, let s = t.text, !s.isEmpty { return s }
                return nil
            }.joined(separator: "\n\n")
        case .other:
            return []
        }
        guard !text.isEmpty else { return [] }
        return [
            Block(
                id: userBubbleBlockId(entryId: single.id),
                kind: .userBubble(text: text))
        ]
    }

    /// The user bubble block id must stay constant across the
    /// `.localUser → .remote.user` transition: `confirm` goes through
    /// `.update(id, newKind)`. A changed id degrades to remove + insert and
    /// wipes animation / selection.
    private static func userBubbleBlockId(entryId: UUID) -> UUID {
        StableBlockID.derive("entry", entryId.uuidString, "userBubble")
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
        // SessionHandle2's `GroupEntry`: `activeTitle` (last child
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

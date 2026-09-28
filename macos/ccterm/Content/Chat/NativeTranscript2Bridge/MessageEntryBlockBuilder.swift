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
///   `AssistantMessage.content` order. Consecutive text blocks buffer
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
        let stripped = strippedCaption(local.text)
        if !stripped.isEmpty {
            out.append(
                Block(
                    id: userBubbleBlockId(entryId: single.id),
                    kind: .userBubble(
                        text: stripped,
                        isQueued: single.delivery == .queued)))
        }
        return out
    }

    private static func remoteUserBlocks(
        _ user: UserMessage,
        single: SingleEntry
    ) -> [Block] {
        // Text blocks concatenate into the bubble caption; image blocks decode
        // into the attachments strip. tool_result blocks are dropped — they're
        // already merged into the matching assistant's toolGroup.
        var images: [NSImage] = []
        var texts: [String] = []
        for block in user.content {
            switch block {
            case .text(let text):
                if !text.isEmpty { texts.append(text) }
            case .image(let image):
                guard case .base64(_, let encoded) = image.source,
                    let data = Data(base64Encoded: encoded),
                    let ns = NSImage(data: data)
                else { continue }
                images.append(ns)
            default:
                continue
            }
        }
        var out: [Block] = []
        if !images.isEmpty {
            out.append(
                Block(
                    id: userAttachmentsBlockId(entryId: single.id),
                    kind: .userAttachments(images: images)))
        }
        let stripped = strippedCaption(texts.joined(separator: "\n\n"))
        if !stripped.isEmpty {
            out.append(
                Block(
                    id: userBubbleBlockId(entryId: single.id),
                    kind: .userBubble(text: stripped)))
        }
        return out
    }

    /// Cosmetic: drop the `[Image #N]` placeholders the Claude CLI
    /// inlines next to each image content block. The bubble already
    /// renders alongside the attachments row, so the marker reads as
    /// noise; removing it visually de-dupes the two surfaces.
    ///
    /// Display-only — the CLI's wire text is untouched (`LocalUserInput.text`
    /// still carries the original form, so the next send round-trips
    /// the user's verbatim string).
    nonisolated private static let imageMarkerRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\[Image\\s*#?\\s*\\d+\\s*\\]")
    }()

    nonisolated private static func strippedCaption(_ text: String?) -> String {
        guard let raw = text, !raw.isEmpty else { return "" }
        guard let regex = imageMarkerRegex else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        let cleaned = regex.stringByReplacingMatches(
            in: raw, options: [], range: range, withTemplate: "")
        // Collapse the blank lines / spaces the placeholder left behind so
        // the remaining body reads naturally — multi-line gaps get squashed
        // to single newlines, runs of horizontal whitespace to one space.
        let normalizedNewlines =
            cleaned
            .replacingOccurrences(
                of: "\\n[\\t ]*\\n[\\t ]*\\n+",
                with: "\n\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "[\\t ]{2,}", with: " ", options: .regularExpression)
        return normalizedNewlines.trimmingCharacters(in: .whitespacesAndNewlines)
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
        _ assistant: AssistantMessage,
        single: SingleEntry
    ) -> [Block] {
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

        for (idx, block) in assistant.content.enumerated() {
            switch block {
            case .text(let text):
                if !text.isEmpty {
                    if textBuffer.isEmpty { textStartIdx = idx }
                    textBuffer.append(text)
                }
            case .toolUse(let tu):
                flushText()
                // The CLI gives every tool_use an id; an empty one only
                // appears in dirty data. The `tu|<idx>` fallback keeps child
                // id derivation stable; its result lookup simply misses.
                let toolUseId = tu.id.isEmpty ? "tu|\(single.id.uuidString)|\(idx)" : tu.id
                let child = ToolUseToChild.make(
                    toolUse: tu,
                    toolUseId: toolUseId,
                    result: single.toolResults[tu.id])
                // Single-tool group: all three title states derive from the
                // same tu. With one tool, "aggregated progressive" degrades
                // to "per-tool progressive"; introducing `activeCountPhrase(1)`
                // would replace "Reading foo.swift" with the vaguer
                // "Reading 1 file".
                let activeTitle = tu.activeFragment ?? tu.name
                let completedTitle = tu.completedFragment ?? tu.name
                let group = ToolGroupBlock(
                    activeTitle: activeTitle,
                    expandedActiveTitle: activeTitle,
                    completedTitle: completedTitle,
                    children: [child])
                let blockId = StableBlockID.derive(
                    "entry", single.id.uuidString, "tg", String(idx))
                out.append(Block(id: blockId, kind: .toolGroup(group)))
            default:
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
            guard case .assistant(let a) = item.remoteMessage else { continue }
            for (blockIdx, block) in a.content.enumerated() {
                guard case .toolUse(let tu) = block else { continue }
                let toolUseId = tu.id.isEmpty ? "tu|\(group.id.uuidString)|\(itemIdx)|\(blockIdx)" : tu.id
                children.append(
                    ToolUseToChild.make(
                        toolUse: tu,
                        toolUseId: toolUseId,
                        result: item.toolResults[tu.id]))
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

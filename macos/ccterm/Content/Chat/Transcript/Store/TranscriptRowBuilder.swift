import AgentSDK
import AppKit

/// Flattens `[Message2]` into `[TranscriptRow]`. Pure data transform — no
/// view, no Session/entry/bridge import; the grouping rules are rewritten
/// here against the raw AgentSDK types.
///
/// Walk messages in document order, expanding each into a stream of
/// elements by **content-block order** (assistant text/thinking →
/// markdown block rows, assistant tool_use → tool element, user
/// text/image → bubble / attachments, user tool_result → skipped). Each
/// maximal run of consecutive tool elements folds into a **single**
/// group-header row carrying the aggregated title; the individual tools
/// (and their results) are not rendered.
enum TranscriptRowBuilder {

    /// One element in the flattened document stream. `.tool` carries a
    /// unique `seed` token (the tool_use id, or a message/block-position
    /// fallback) so a group's derived id can't collide with another group
    /// that happens to hold the same tool kinds in the same order.
    private enum Element {
        case row(TranscriptRow)
        case tool(toolUse: ToolUse, seed: String)
    }

    static func build(messages: [Message2]) -> [TranscriptRow] {
        var elements: [Element] = []
        for (index, message) in messages.enumerated() {
            switch message {
            case .assistant(let a):
                appendAssistant(a, messageIndex: index, into: &elements)
            case .user(let u):
                appendUser(u, messageIndex: index, into: &elements)
            default:
                break
            }
        }
        return foldGroups(elements)
    }

    // MARK: - Assistant / user expansion

    private static func appendAssistant(
        _ a: Message2Assistant, messageIndex: Int, into elements: inout [Element]
    ) {
        // Subagent turns (nested under an Agent tool) are internal — skip.
        guard a.parentToolUseId == nil, let blocks = a.message?.content else { return }
        for (blockIndex, block) in blocks.enumerated() {
            let idPrefix = "msg\(messageIndex)|c\(blockIndex)"
            switch block {
            case .text(let t):
                appendMarkdown(t.text, idPrefix: idPrefix, into: &elements)
            case .thinking(let th):
                appendMarkdown(th.thinking, idPrefix: idPrefix, into: &elements)
            case .toolUse(let tu):
                let seed = tu.id ?? "msg\(messageIndex)|tool\(blockIndex)"
                elements.append(.tool(toolUse: tu, seed: seed))
            case .unknown:
                break
            }
        }
    }

    private static func appendMarkdown(
        _ source: String?, idPrefix: String, into elements: inout [Element]
    ) {
        guard let source, !source.isEmpty else { return }
        for block in MarkdownToBlocks.blocks(source: source, idPrefix: idPrefix) {
            elements.append(.row(TranscriptRow(id: block.id, content: .block(block))))
        }
    }

    private static func appendUser(
        _ u: Message2User, messageIndex: Int, into elements: inout [Element]
    ) {
        // Drop sub-agent / synthetic / compact-summary / transcript-only /
        // task-notification envelopes before touching content.
        guard passesUserMetaFilter(u) else { return }
        let (texts, images) = userContent(u)
        // A message that carried only a `tool_result` (no real text / image)
        // produces no bubble.
        guard texts.contains(where: { !$0.isEmpty }) || !images.isEmpty else { return }

        // Attachments strip sits above the bubble, matching the input
        // bar's stacked "one user turn" reading.
        if !images.isEmpty {
            let id = StableBlockID.derive("msg\(messageIndex)", "userAttachments")
            elements.append(
                .row(
                    TranscriptRow(
                        id: id,
                        content: .block(
                            Block(id: id, kind: .userAttachments(images: images))))))
        }
        let joined = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !joined.isEmpty {
            let id = StableBlockID.derive("msg\(messageIndex)", "userBubble")
            elements.append(
                .row(
                    TranscriptRow(
                        id: id,
                        content: .block(Block(id: id, kind: .userBubble(text: joined))))))
        }
    }

    // MARK: - Grouping

    /// Fold each maximal run of consecutive `.tool` elements into a single
    /// group-header row. A single tool still forms a group.
    private static func foldGroups(_ elements: [Element]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [(toolUse: ToolUse, seed: String)] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            let seed = run.map(\.seed).joined(separator: "-")
            rows.append(
                TranscriptRow(
                    id: StableBlockID.derive("toolgroup", seed),
                    content: .groupHeader(
                        title: TranscriptToolNarration.groupTitle(for: run.map(\.toolUse)))))
            run.removeAll(keepingCapacity: true)
        }

        for element in elements {
            switch element {
            case .row(let row):
                flushRun()
                rows.append(row)
            case .tool(let toolUse, let seed):
                run.append((toolUse, seed))
            }
        }
        flushRun()
        return rows
    }

    // MARK: - User content extraction

    /// Metadata visibility filter, rewritten from the Session-domain
    /// `Message2User.isVisible`: drop sub-agent, synthetic, compact-summary,
    /// transcript-only, and task-notification envelopes. The content check
    /// (has real text / image) is applied by the caller so the split is
    /// computed once.
    private static func passesUserMetaFilter(_ u: Message2User) -> Bool {
        u.parentToolUseId == nil
            && u.isSynthetic != true
            && u.isCompactSummary != true
            && u.isVisibleInTranscriptOnly != true
            && u.origin?.kind != "task-notification"
            && !startsWithTaskNotificationEnvelope(u)
    }

    private static func startsWithTaskNotificationEnvelope(_ u: Message2User) -> Bool {
        let marker = "<task-notification>"
        switch u.message?.content {
        case .string(let s)?:
            return s.hasPrefix(marker)
        case .array(let items)?:
            for item in items {
                if case .text(let t) = item, let txt = t.text {
                    return txt.hasPrefix(marker)
                }
            }
            return false
        default:
            return false
        }
    }

    /// Split a user message's content into its real text fragments and
    /// decodable inline images. `tool_result` blocks are ignored.
    private static func userContent(_ u: Message2User) -> (texts: [String], images: [NSImage]) {
        switch u.message?.content {
        case .string(let s)?:
            return ([s], [])
        case .array(let items)?:
            var texts: [String] = []
            var images: [NSImage] = []
            for item in items {
                switch item {
                case .text(let t):
                    if let s = t.text, !s.isEmpty { texts.append(s) }
                case .image(let img):
                    if let decoded = decodeImage(img) { images.append(decoded) }
                case .toolResult, .unknown:
                    break
                }
            }
            return (texts, images)
        default:
            return ([], [])
        }
    }

    /// Decode an inline image's base64 `source.data` into an `NSImage`.
    /// Returns `nil` when the source is a reference / paste-id form we
    /// can't materialize from the history file (the bubble still renders;
    /// the attachment strip is simply omitted for that image).
    private static func decodeImage(_ image: Image) -> NSImage? {
        guard let base64 = image.source?.data,
            let data = Data(base64Encoded: base64),
            let decoded = NSImage(data: data)
        else { return nil }
        return decoded
    }
}

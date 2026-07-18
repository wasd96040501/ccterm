import AgentSDK
import AppKit

/// Tree-ifies `[Message2]` into `[TranscriptNode]` roots (SPEC §4 / §8
/// decision 2). Pure data transform — no view, no Session/entry/bridge
/// import; the grouping + tool-pairing rules are rewritten here against
/// the raw AgentSDK types.
///
/// Two passes:
/// 1. Collect every `tool_result` (keyed by `tool_use_id`) from user
///    messages — a result may sit in a later message than its `tool_use`.
/// 2. Walk messages in document order, expanding each into a stream of
///    elements by **content-block order** (assistant text/thinking →
///    markdown top nodes, assistant tool_use → tool element, user
///    text/image → bubble / attachments, user tool_result → skipped,
///    already paired). Consecutive tool elements fold into one group.
enum TranscriptTreeBuilder {

    /// A paired tool result: the raw block (`content` + `isError`) plus
    /// the message's typed projection.
    private struct ToolResultPair {
        let item: ItemToolResult
        let typed: ToolUseResult?
    }

    /// One element in the flattened document stream.
    private enum Element {
        case leaf(TranscriptNode)
        case tool(toolUse: ToolUse, toolUseId: String)
    }

    static func build(messages: [Message2]) -> [TranscriptNode] {
        let pairing = collectToolResults(messages)

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

        return foldGroups(elements, pairing: pairing)
    }

    // MARK: - Pass 1: tool-result pairing

    private static func collectToolResults(_ messages: [Message2]) -> [String: ToolResultPair] {
        var pairing: [String: ToolResultPair] = [:]
        for message in messages {
            guard case .user(let u) = message,
                let block = toolResultBlock(u),
                let id = block.toolUseId
            else { continue }
            // First occurrence wins — a tool_use pairs with exactly one
            // result, in document order.
            if pairing[id] == nil {
                pairing[id] = ToolResultPair(item: block, typed: u.toolUseResult)
            }
        }
        return pairing
    }

    // MARK: - Pass 2: assistant / user expansion

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
                let toolUseId = tu.id ?? "msg\(messageIndex)|tool\(blockIndex)"
                elements.append(.tool(toolUse: tu, toolUseId: toolUseId))
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
            elements.append(.leaf(TranscriptNode(id: block.id, content: .block(block))))
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
        // produces no bubble — it was paired in pass 1.
        guard texts.contains(where: { !$0.isEmpty }) || !images.isEmpty else { return }

        // Attachments strip sits above the bubble, matching the input
        // bar's stacked "one user turn" reading.
        if !images.isEmpty {
            elements.append(
                .leaf(
                    TranscriptNode(
                        id: StableBlockID.derive("msg\(messageIndex)", "userAttachments"),
                        content: .block(
                            Block(
                                id: StableBlockID.derive("msg\(messageIndex)", "userAttachments"),
                                kind: .userAttachments(images: images))))))
        }
        let joined = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !joined.isEmpty {
            elements.append(
                .leaf(
                    TranscriptNode(
                        id: StableBlockID.derive("msg\(messageIndex)", "userBubble"),
                        content: .block(
                            Block(
                                id: StableBlockID.derive("msg\(messageIndex)", "userBubble"),
                                kind: .userBubble(text: joined))))))
        }
    }

    // MARK: - Grouping

    /// Fold each maximal run of consecutive `.tool` elements into a
    /// tool-group node. A single tool still forms a group (SPEC §4).
    private static func foldGroups(
        _ elements: [Element], pairing: [String: ToolResultPair]
    ) -> [TranscriptNode] {
        var roots: [TranscriptNode] = []
        var run: [(toolUse: ToolUse, toolUseId: String)] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            roots.append(makeGroupNode(run, pairing: pairing))
            run.removeAll(keepingCapacity: true)
        }

        for element in elements {
            switch element {
            case .leaf(let node):
                flushRun()
                roots.append(node)
            case .tool(let toolUse, let toolUseId):
                run.append((toolUse, toolUseId))
            }
        }
        flushRun()
        return roots
    }

    private static func makeGroupNode(
        _ run: [(toolUse: ToolUse, toolUseId: String)],
        pairing: [String: ToolResultPair]
    ) -> TranscriptNode {
        let toolChildren: [TranscriptNode] = run.map { entry in
            let pair = pairing[entry.toolUseId]
            let child = TranscriptToolChildBuilder.make(
                toolUse: entry.toolUse,
                toolUseId: entry.toolUseId,
                result: pair?.item,
                typed: pair?.typed)
            let bodyNodes: [TranscriptNode] =
                child.hasExpandableBody
                ? [
                    TranscriptNode(
                        id: StableBlockID.derive("toolbody", entry.toolUseId),
                        content: .toolBody(child))
                ]
                : []
            return TranscriptNode(
                id: StableBlockID.derive("toolheader", entry.toolUseId),
                content: .header(
                    title: TranscriptToolNarration.toolHeaderTitle(entry.toolUse)),
                children: bodyNodes)
        }
        let groupSeed = run.map(\.toolUseId).joined(separator: "-")
        return TranscriptNode(
            id: StableBlockID.derive("toolgroup", groupSeed),
            content: .header(
                title: TranscriptToolNarration.groupTitle(for: run.map(\.toolUse))),
            children: toolChildren)
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
    /// decodable inline images. `tool_result` blocks are ignored (paired
    /// separately in pass 1).
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

    /// The first `tool_result` block in a user message (a message
    /// typically carries at most one).
    private static func toolResultBlock(_ u: Message2User) -> ItemToolResult? {
        guard case .array(let items)? = u.message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item { return r }
        }
        return nil
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

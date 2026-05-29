import AgentSDK
import Foundation

/// Pure, value-type folder for the SDK's partial-message stream
/// (`Session.onStreamEvent`, gated by `includePartialMessages`). One instance
/// lives on `SessionRuntime` per turn. It folds the SSE-style sub-events into:
///
/// - the in-flight assistant message's accumulated **text** — `text_delta`
///   only; `thinking_delta` / `input_json_delta` are deliberately ignored,
///   because thinking is not rendered and tool calls render through the
///   finalized `onMessage` path.
/// - the turn's running **token usage** (input + output, excluding cache),
///   read from `message_start` / `message_delta` usage payloads.
///
/// Stream indices reset at each `message_start`, and a turn produces several
/// assistant messages, so text is tracked only for the *current* message
/// (keyed by content-block index) while usage accumulates across every message
/// (keyed by CLI `message.id`).
///
/// No UI, no markdown parsing, no actor isolation — unit-tested in isolation
/// (`StreamingTurnAssemblerTests`).
struct StreamingTurnAssembler {

    /// CLI message id currently streaming, or nil before the first
    /// `message_start` / after `reset()`.
    private(set) var currentMessageId: String?

    /// Accumulated text for the current message, keyed by content-block index.
    private var textByBlockIndex: [Int: String] = [:]

    /// Per-message usage keyed by CLI message id. Stored (not summed) per
    /// message so a finalized envelope can idempotently re-state it.
    private(set) var usageByMessage: [String: TurnTokenUsage] = [:]

    /// Message ids in first-seen order — keeps `turnUsage` deterministic.
    private var messageOrder: [String] = []

    init() {}

    /// Drop all turn state. Call when a new user turn starts.
    mutating func reset() {
        currentMessageId = nil
        textByBlockIndex = [:]
        usageByMessage = [:]
        messageOrder = []
    }

    /// Sum of every message's usage seen this turn.
    var turnUsage: TurnTokenUsage {
        messageOrder.reduce(.zero) { $0 + (usageByMessage[$1] ?? .zero) }
    }

    /// The current streaming message's text: content blocks joined by blank
    /// lines, matching `MessageEntryBlockBuilder`'s text-buffer join. Empty
    /// when no text has streamed for the current message.
    var currentText: String {
        textByBlockIndex.keys.sorted()
            .compactMap { textByBlockIndex[$0] }
            .joined(separator: "\n\n")
    }

    /// What changed as a result of folding one event. Callers act on the
    /// flags they care about (re-render text, refresh usage UI).
    struct Outcome: Equatable {
        /// A `message_start` switched the current message. The previous
        /// message's preview should be finalized by its `onMessage` envelope.
        var startedMessage: Bool = false
        /// The current message's visible text grew.
        var textChanged: Bool = false
        /// Turn token usage changed.
        var usageChanged: Bool = false

        var isNoop: Bool { !startedMessage && !textChanged && !usageChanged }
    }

    /// Fold one typed stream event into the turn state.
    @discardableResult
    mutating func consume(_ event: Message2StreamEvent) -> Outcome {
        guard let body = event.event else { return Outcome() }
        switch body {
        case .messageStart(let s):
            return handleMessageStart(s)
        case .contentBlockDelta(let d):
            return handleContentBlockDelta(d)
        case .messageDelta(let d):
            return handleMessageDelta(d)
        case .contentBlockStart, .contentBlockStop, .messageStop, .unknown:
            return Outcome()
        }
    }

    // MARK: - Event handlers

    private mutating func handleMessageStart(_ s: StreamMessageStart) -> Outcome {
        guard let msg = s.message, let id = msg["id"] as? String else { return Outcome() }
        var out = Outcome()
        if id != currentMessageId {
            currentMessageId = id
            textByBlockIndex = [:]
            out.startedMessage = true
            noteMessage(id)
        }
        if let usage = msg["usage"] as? [String: Any], applyUsage(usage, to: id) {
            out.usageChanged = true
        }
        return out
    }

    private mutating func handleContentBlockDelta(_ d: StreamContentBlockDelta) -> Outcome {
        guard let idx = d.index,
            let delta = d.delta,
            delta["type"] as? String == "text_delta",
            let chunk = delta["text"] as? String,
            !chunk.isEmpty
        else { return Outcome() }
        textByBlockIndex[idx, default: ""] += chunk
        return Outcome(textChanged: true)
    }

    private mutating func handleMessageDelta(_ d: StreamMessageDelta) -> Outcome {
        guard let id = currentMessageId, let usage = d.usage else { return Outcome() }
        return Outcome(usageChanged: applyUsage(usage, to: id))
    }

    /// Reconcile a message's usage against an authoritative finalized envelope.
    /// Overwrites the streamed estimate; absent fields are left untouched.
    @discardableResult
    mutating func recordUsage(messageId id: String, input: Int?, output: Int?) -> Bool {
        var rec = usageByMessage[id] ?? .zero
        let before = rec
        if let input { rec.inputTokens = input }
        if let output { rec.outputTokens = output }
        guard rec != before else { return false }
        usageByMessage[id] = rec
        noteMessage(id)
        return true
    }

    // MARK: - Usage

    /// Merge a wire usage dict into the per-message record. Input excludes
    /// cache (we read `input_tokens` only, never the `cache_*` fields).
    /// `message_delta` usage often omits `input_tokens`, so each field is
    /// overwritten only when present — the prior value survives otherwise.
    private mutating func applyUsage(_ usage: [String: Any], to id: String) -> Bool {
        var rec = usageByMessage[id] ?? .zero
        let before = rec
        if let input = (usage["input_tokens"] as? NSNumber)?.intValue { rec.inputTokens = input }
        if let output = (usage["output_tokens"] as? NSNumber)?.intValue { rec.outputTokens = output }
        guard rec != before else { return false }
        usageByMessage[id] = rec
        noteMessage(id)
        return true
    }

    private mutating func noteMessage(_ id: String) {
        if !messageOrder.contains(id) { messageOrder.append(id) }
    }
}

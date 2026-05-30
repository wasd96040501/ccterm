import AgentSDK
import Foundation

/// Pure, value-type folder for the SDK's partial-message stream
/// (`Session.onStreamEvent`, gated by `includePartialMessages`). One instance
/// lives on `SessionRuntime` per turn. It folds the SSE-style sub-events into:
///
/// - the in-flight assistant message's accumulated **text** — `text_delta`
///   only; `thinking_delta` / `input_json_delta` never leak into the rendered
///   text, because thinking is not rendered and tool calls render through the
///   finalized `onMessage` path.
/// - the turn's running **token usage** (input + output, excluding cache),
///   read verbatim from the `message_start` / `message_delta` usage payloads
///   and reconciled against the finalized `.assistant` envelope.
///
/// ### Token usage is wire-only — no estimation
///
/// Every token figure surfaced here comes straight off the wire. The CLI emits
/// the authoritative per-message `output_tokens` exactly once, in the trailing
/// `message_delta`; `message_start` and the finalized `.assistant` envelope both
/// carry only a small placeholder (observed at 5) alongside the real
/// `input_tokens`. We apply whatever the wire reports as a per-message
/// high-water mark (`raise`) — we do **not** synthesize a per-character estimate.
///
/// To keep the `↓` counter moving through the (redacted) thinking phase — where
/// no authoritative output lands until the very end — we fold the CLI's own
/// cumulative thinking estimate (`system.thinking_tokens.estimated_tokens`, via
/// `recordThinkingEstimate`) into the same output high-water mark. It's a
/// wire-provided, conservative figure (the CLI under-shoots); the authoritative
/// `message_delta` total, which already includes thinking, supersedes it through
/// the same `max`. So output climbs with the thinking estimate during thinking,
/// then steps to the real total at `message_delta` and stays there (a later
/// placeholder can't drag it back down).
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

    /// Sum of every message's wire usage seen this turn.
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
        // `message_start` carries the real `input_tokens` plus a placeholder
        // `output_tokens` (observed at 5); folded in as a high-water mark.
        if let usage = msg["usage"] as? [String: Any], applyUsage(usage, to: id) {
            out.usageChanged = true
        }
        return out
    }

    private mutating func handleContentBlockDelta(_ d: StreamContentBlockDelta) -> Outcome {
        guard let idx = d.index, let delta = d.delta else { return Outcome() }
        // Only `text_delta` feeds the rendered text. `thinking_delta` /
        // `input_json_delta` are ignored — thinking isn't rendered and tool
        // args render through the finalized `onMessage` path.
        guard delta["type"] as? String == "text_delta",
            let chunk = delta["text"] as? String, !chunk.isEmpty
        else { return Outcome() }
        textByBlockIndex[idx, default: ""] += chunk
        return Outcome(textChanged: true)
    }

    private mutating func handleMessageDelta(_ d: StreamMessageDelta) -> Outcome {
        guard let id = currentMessageId, let usage = d.usage else { return Outcome() }
        // `message_delta` is the authoritative per-message output total.
        return Outcome(usageChanged: applyUsage(usage, to: id))
    }

    /// Reconcile a message's usage against a finalized `.assistant` envelope.
    /// Folds the figures in as a high-water mark (see `raise`) — the envelope
    /// carries the same `output_tokens` *placeholder* as `message_start`, not
    /// the real total, so it must never regress the authoritative figure that
    /// `message_delta` already delivered.
    @discardableResult
    mutating func recordUsage(messageId id: String, input: Int?, output: Int?) -> Bool {
        raise(messageId: id, input: input, output: output)
    }

    /// Fold the CLI's cumulative thinking-token estimate
    /// (`system.thinking_tokens.estimated_tokens`) into the current message's
    /// output high-water mark, so the live `↓` counter climbs through the
    /// redacted thinking phase instead of sitting frozen at the placeholder.
    /// The estimate is conservative (the CLI deliberately under-shoots) and the
    /// authoritative `message_delta` total — which already *includes* thinking —
    /// supersedes it through the same `max`. Keyed to the in-flight message
    /// (`system.thinking_tokens` carries no message id of its own).
    @discardableResult
    mutating func recordThinkingEstimate(cumulativeEstimate: Int) -> Bool {
        guard let id = currentMessageId else { return false }
        return raise(messageId: id, input: nil, output: cumulativeEstimate)
    }

    // MARK: - Usage

    /// Merge a wire usage dict into the per-message record. Input excludes
    /// cache (we read `input_tokens` only, never the `cache_*` fields).
    private mutating func applyUsage(_ usage: [String: Any], to id: String) -> Bool {
        raise(
            messageId: id,
            input: (usage["input_tokens"] as? NSNumber)?.intValue,
            output: (usage["output_tokens"] as? NSNumber)?.intValue)
    }

    /// Raise a message's per-token high-water mark; absent fields are left
    /// untouched, and a smaller incoming value never lowers a stored one.
    ///
    /// A single message id is reported several times with the *same* token
    /// fields meaning different things: `message_start` and the finalized
    /// `.assistant` envelope both carry a small `output_tokens` placeholder
    /// (observed at 5), while the authoritative cumulative total arrives once,
    /// in the trailing `message_delta` (observed at 1556 incl. thinking) —
    /// verified against a real subprocess in `ThinkingUsageSmoke`. Keeping the
    /// maximum makes the order events arrive in irrelevant and stops a stale
    /// placeholder from clobbering the real figure at turn close.
    @discardableResult
    private mutating func raise(messageId id: String, input: Int?, output: Int?) -> Bool {
        var rec = usageByMessage[id] ?? .zero
        let before = rec
        if let input { rec.inputTokens = max(rec.inputTokens, input) }
        if let output { rec.outputTokens = max(rec.outputTokens, output) }
        guard rec != before else { return false }
        usageByMessage[id] = rec
        noteMessage(id)
        return true
    }

    private mutating func noteMessage(_ id: String) {
        if !messageOrder.contains(id) { messageOrder.append(id) }
    }
}

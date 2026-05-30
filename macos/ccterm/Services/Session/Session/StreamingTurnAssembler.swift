import AgentSDK
import Foundation

/// Pure, value-type folder for the SDK's partial-message stream
/// (`Session.onStreamEvent`, gated by `includePartialMessages`) plus the CLI's
/// `system.thinking_tokens` progress messages. One instance lives on
/// `SessionRuntime` per turn. It folds events into:
///
/// - the in-flight assistant message's accumulated **text** — `text_delta`
///   only; `thinking_delta` / `input_json_delta` never leak into the rendered
///   text, because thinking is not rendered and tool calls render through the
///   finalized `onMessage` path.
/// - the turn's running **token usage** (input + output, excluding cache).
///
/// ### How the live `↓` output counter is built (claude.app parity)
///
/// The wire delivers the authoritative per-message `output_tokens` **exactly
/// once**, in the trailing `message_delta` — `message_start` and the finalized
/// `.assistant` envelope only carry a small placeholder (observed at 5), and
/// `text_delta` carries no token count at all. So to make the counter climb
/// during the stream (instead of sitting frozen until the very end), we keep a
/// client-side estimate per message, exactly like the `claude` CLI / desktop
/// app do (they show `responseLength/4`, reconciled to `output_tokens×4` at the
/// end):
///
///   • `textUnits`  — a CJK-weighted per-character estimate from streamed
///     `text_delta` (CJK/kana/hangul tokenise denser than Latin).
///   • `thinkingTokens` — the CLI's cumulative thinking estimate from
///     `system.thinking_tokens.estimated_tokens` (the thinking text itself is
///     redacted on the wire), folded in via `recordThinkingEstimate`.
///
/// The displayed output for a message is `max(wireFloor, textUnits +
/// thinkingTokens)`: the estimate drives the counter up while the message
/// streams, and the authoritative `message_delta` total (which already includes
/// thinking) overtakes it through the same `max` — so the counter never snaps
/// down, matching claude.app. Input excludes cache (`input_tokens` only).
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

    /// Wire-reported usage floor per message id (high-water mark): the real
    /// `input_tokens`, and the output *floor* — the `message_start` placeholder
    /// raised to the authoritative `message_delta` total.
    private(set) var usageByMessage: [String: TurnTokenUsage] = [:]

    /// Client-side output-estimate components, summed and shown until the
    /// authoritative floor overtakes them (`displayedOutput`). Both reset per
    /// turn with `reset()`.
    private var textUnitsByMessage: [String: Double] = [:]  // CJK-weighted text estimate
    private var thinkingTokensByMessage: [String: Int] = [:]  // cumulative system.thinking_tokens

    /// Message ids in first-seen order — keeps `turnUsage` deterministic.
    private var messageOrder: [String] = []

    init() {}

    /// Drop all turn state. Call when a new user turn starts.
    mutating func reset() {
        currentMessageId = nil
        textByBlockIndex = [:]
        usageByMessage = [:]
        textUnitsByMessage = [:]
        thinkingTokensByMessage = [:]
        messageOrder = []
    }

    /// Displayed output for one message: the larger of the wire floor and the
    /// client-side estimate (text + thinking). Matches claude.app, which shows
    /// `max(charEstimate, authoritative)` and never snaps the counter down.
    private func displayedOutput(_ id: String) -> Int {
        let floor = usageByMessage[id]?.outputTokens ?? 0
        let estimate = Int((textUnitsByMessage[id] ?? 0).rounded()) + (thinkingTokensByMessage[id] ?? 0)
        return max(floor, estimate)
    }

    /// Sum of every message's input (wire) + displayed output (floor∨estimate).
    var turnUsage: TurnTokenUsage {
        messageOrder.reduce(.zero) { acc, id in
            acc
                + TurnTokenUsage(
                    inputTokens: usageByMessage[id]?.inputTokens ?? 0,
                    outputTokens: displayedOutput(id))
        }
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
        // `output_tokens` (observed at 5); both raise the wire floor.
        if let usage = msg["usage"] as? [String: Any], applyUsage(usage, to: id) {
            out.usageChanged = true
        }
        return out
    }

    private mutating func handleContentBlockDelta(_ d: StreamContentBlockDelta) -> Outcome {
        guard let idx = d.index, let delta = d.delta else { return Outcome() }
        // Only `text_delta` feeds the rendered text + the output estimate.
        // `thinking_delta` / `input_json_delta` are ignored here — thinking is
        // redacted on the wire and accounted via `system.thinking_tokens`; tool
        // args render through the finalized `onMessage` path.
        guard delta["type"] as? String == "text_delta",
            let chunk = delta["text"] as? String, !chunk.isEmpty
        else { return Outcome() }
        textByBlockIndex[idx, default: ""] += chunk
        return Outcome(textChanged: true, usageChanged: growTextEstimate(by: chunk))
    }

    private mutating func handleMessageDelta(_ d: StreamMessageDelta) -> Outcome {
        guard let id = currentMessageId, let usage = d.usage else { return Outcome() }
        // `message_delta` is the authoritative per-message output total.
        return Outcome(usageChanged: applyUsage(usage, to: id))
    }

    /// Fold the CLI's cumulative thinking-token estimate
    /// (`system.thinking_tokens.estimated_tokens`) into the current message's
    /// estimate so the `↓` counter climbs through the redacted thinking phase.
    /// Cumulative per thinking block — kept as a max so a per-block reset can't
    /// drop the running total. Keyed to the in-flight message
    /// (`system.thinking_tokens` carries no message id of its own).
    @discardableResult
    mutating func recordThinkingEstimate(cumulativeEstimate: Int) -> Bool {
        guard let id = currentMessageId else { return false }
        let before = displayedOutput(id)
        thinkingTokensByMessage[id] = max(thinkingTokensByMessage[id] ?? 0, cumulativeEstimate)
        noteMessage(id)
        return displayedOutput(id) != before
    }

    /// Reconcile a message's usage against a finalized `.assistant` envelope.
    /// Raises the wire floor (input + the placeholder output, which can't
    /// regress the authoritative total `message_delta` already delivered).
    @discardableResult
    mutating func recordUsage(messageId id: String, input: Int?, output: Int?) -> Bool {
        raiseFloor(messageId: id, input: input, output: output)
    }

    // MARK: - Estimate + floor

    /// Grow the current message's CJK-weighted text estimate from one streamed
    /// `text_delta`. Returns whether the rounded displayed output moved (so a
    /// burst of sub-token chars flushes only on a visible change).
    private mutating func growTextEstimate(by chunk: String) -> Bool {
        guard let id = currentMessageId else { return false }
        let before = displayedOutput(id)
        textUnitsByMessage[id, default: 0] += Self.estimateTokens(chunk)
        noteMessage(id)
        return displayedOutput(id) != before
    }

    /// Merge a wire usage dict into the per-message floor. Input excludes cache
    /// (`input_tokens` only, never the `cache_*` fields).
    private mutating func applyUsage(_ usage: [String: Any], to id: String) -> Bool {
        raiseFloor(
            messageId: id,
            input: (usage["input_tokens"] as? NSNumber)?.intValue,
            output: (usage["output_tokens"] as? NSNumber)?.intValue)
    }

    /// Raise a message's wire floor (input + output) as a high-water mark;
    /// absent fields untouched, a smaller incoming value never lowers a stored
    /// one. `output` here is the authoritative/placeholder figure — the
    /// estimate is layered on top in `displayedOutput`. Returns whether the
    /// input or the *displayed* output moved.
    @discardableResult
    private mutating func raiseFloor(messageId id: String, input: Int?, output: Int?) -> Bool {
        let beforeOutput = displayedOutput(id)
        let beforeInput = usageByMessage[id]?.inputTokens ?? 0
        var rec = usageByMessage[id] ?? .zero
        if let input { rec.inputTokens = max(rec.inputTokens, input) }
        if let output { rec.outputTokens = max(rec.outputTokens, output) }
        usageByMessage[id] = rec
        noteMessage(id)
        return rec.inputTokens != beforeInput || displayedOutput(id) != beforeOutput
    }

    /// Cheap, monotonic per-character token estimate (the `claude` CLI / desktop
    /// app show a similar live chars/4 count). Wide scripts (CJK, kana, hangul,
    /// fullwidth) tokenise denser than Latin, so they count for more.
    /// Deliberately conservative for Latin; the authoritative `message_delta`
    /// total supersedes it via `max`, so an over-eager estimate can't pin the
    /// displayed total above the truth once the real figure lands.
    private static func estimateTokens(_ s: String) -> Double {
        var t = 0.0
        for u in s.unicodeScalars {
            t += isWide(u) ? 1.0 : 0.3
        }
        return t
    }

    /// Whether a scalar belongs to a wide / dense-tokenising script.
    private static func isWide(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1100...0x11FF,  // Hangul Jamo
            0x2E80...0x9FFF,  // CJK radicals … unified ideographs
            0xA960...0xA97F,  // Hangul Jamo Extended-A
            0xAC00...0xD7FF,  // Hangul syllables
            0xF900...0xFAFF,  // CJK compatibility ideographs
            0xFF00...0xFFEF,  // Halfwidth/Fullwidth forms
            0x20000...0x3FFFF:  // CJK extensions B+
            return true
        default:
            return false
        }
    }

    private mutating func noteMessage(_ id: String) {
        if !messageOrder.contains(id) { messageOrder.append(id) }
    }
}

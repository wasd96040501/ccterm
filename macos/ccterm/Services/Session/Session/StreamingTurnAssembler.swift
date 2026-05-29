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
///   read from `message_start` / `message_delta` usage payloads, **plus a live
///   output estimate** so the counter keeps moving mid-message.
///
/// ### Why a live output estimate
///
/// The CLI emits authoritative `output_tokens` exactly **once per message** —
/// in the trailing `message_delta` (verified against a real subprocess in
/// `PartialMessagesSmoke`). `message_start` only carries a placeholder
/// (`output_tokens == 1`). So without an estimate the running counter would
/// sit frozen at 1 for the entire message and snap to the real total only at
/// the very end. We therefore accumulate a cheap per-character estimate from
/// every streamed `text_delta` **and** `thinking_delta` (thinking counts
/// toward the message's `output_tokens`), and surface `max(estimate,
/// placeholder)` until the authoritative figure lands — at which point the
/// authoritative value takes over exactly (no `max`, so an over-eager estimate
/// can't pin the displayed total above the truth).
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

    /// Live per-character output estimate keyed by CLI message id, in
    /// fractional tokens (rounded only at read time). Grows on every streamed
    /// `text_delta` / `thinking_delta`; superseded by the authoritative figure.
    private var estimatedOutputUnits: [String: Double] = [:]

    /// Message ids whose authoritative `output_tokens` has landed (a
    /// `message_delta` or a finalized envelope). Once present, the estimate is
    /// abandoned for that message and the authoritative value is shown exactly.
    private var authoritativeOutput: Set<String> = []

    /// Message ids in first-seen order — keeps `turnUsage` deterministic.
    private var messageOrder: [String] = []

    init() {}

    /// Drop all turn state. Call when a new user turn starts.
    mutating func reset() {
        currentMessageId = nil
        textByBlockIndex = [:]
        usageByMessage = [:]
        estimatedOutputUnits = [:]
        authoritativeOutput = []
        messageOrder = []
    }

    /// Per-message usage with the live output estimate folded in: while a
    /// message's authoritative `output_tokens` hasn't arrived, the larger of
    /// (placeholder, estimate) is shown; afterward the authoritative value is
    /// shown verbatim.
    private func usage(for id: String) -> TurnTokenUsage {
        let auth = usageByMessage[id] ?? .zero
        guard !authoritativeOutput.contains(id) else { return auth }
        let est = Int((estimatedOutputUnits[id] ?? 0).rounded())
        return TurnTokenUsage(inputTokens: auth.inputTokens, outputTokens: max(auth.outputTokens, est))
    }

    /// Sum of every message's usage seen this turn (estimate folded in).
    var turnUsage: TurnTokenUsage {
        messageOrder.reduce(.zero) { $0 + usage(for: $1) }
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
        // `message_start.output_tokens` is a placeholder (observed as 1) — not
        // authoritative, so the live estimate is still allowed to override it.
        if let usage = msg["usage"] as? [String: Any], applyUsage(usage, to: id, authoritative: false) {
            out.usageChanged = true
        }
        return out
    }

    private mutating func handleContentBlockDelta(_ d: StreamContentBlockDelta) -> Outcome {
        guard let idx = d.index, let delta = d.delta else { return Outcome() }
        let kind = delta["type"] as? String
        switch kind {
        case "text_delta":
            guard let chunk = delta["text"] as? String, !chunk.isEmpty else { return Outcome() }
            textByBlockIndex[idx, default: ""] += chunk
            // Visible text grew AND output tokens grew — both drive a flush so
            // the running counter keeps climbing through the message body.
            return Outcome(textChanged: true, usageChanged: growEstimate(by: chunk))
        case "thinking_delta":
            // Thinking is not rendered, but its tokens count toward the
            // message's `output_tokens`, so it feeds the estimate only.
            guard let chunk = delta["thinking"] as? String, !chunk.isEmpty else { return Outcome() }
            return Outcome(usageChanged: growEstimate(by: chunk))
        default:
            // `input_json_delta` (tool args) etc. — not part of visible text or
            // the estimate.
            return Outcome()
        }
    }

    private mutating func handleMessageDelta(_ d: StreamMessageDelta) -> Outcome {
        guard let id = currentMessageId, let usage = d.usage else { return Outcome() }
        // `message_delta` is the authoritative per-message output total.
        return Outcome(usageChanged: applyUsage(usage, to: id, authoritative: true))
    }

    /// Reconcile a message's usage against an authoritative finalized envelope.
    /// Overwrites the streamed estimate; absent fields are left untouched.
    @discardableResult
    mutating func recordUsage(messageId id: String, input: Int?, output: Int?) -> Bool {
        var rec = usageByMessage[id] ?? .zero
        let before = rec
        if let input { rec.inputTokens = input }
        if let output {
            rec.outputTokens = output
            authoritativeOutput.insert(id)
        }
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
    /// `authoritative` marks the message's output total as final so the live
    /// estimate stops overriding it.
    private mutating func applyUsage(_ usage: [String: Any], to id: String, authoritative: Bool) -> Bool {
        var rec = usageByMessage[id] ?? .zero
        let before = rec
        var changed = false
        if let input = (usage["input_tokens"] as? NSNumber)?.intValue { rec.inputTokens = input }
        if let output = (usage["output_tokens"] as? NSNumber)?.intValue {
            rec.outputTokens = output
            if authoritative, !authoritativeOutput.contains(id) {
                authoritativeOutput.insert(id)
                // The estimate-vs-authoritative crossover changes the displayed
                // value even when the stored record is byte-identical.
                changed = true
            }
        }
        usageByMessage[id] = rec
        noteMessage(id)
        return rec != before || changed
    }

    /// Fold a streamed chunk into the current message's output estimate.
    /// Returns whether the rounded estimate moved (so the caller only flushes
    /// on a visible change).
    private mutating func growEstimate(by chunk: String) -> Bool {
        guard let id = currentMessageId, !authoritativeOutput.contains(id) else { return false }
        let before = Int((estimatedOutputUnits[id] ?? 0).rounded())
        estimatedOutputUnits[id, default: 0] += Self.estimateTokens(chunk)
        noteMessage(id)
        return Int((estimatedOutputUnits[id] ?? 0).rounded()) != before
    }

    /// Cheap, monotonic token estimate from raw characters. Wide scripts (CJK,
    /// kana, hangul, fullwidth) tokenise denser than Latin text, so they count
    /// for more. Deliberately conservative (tends to under-shoot) so the final
    /// authoritative figure is reached by climbing up, not snapping down.
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

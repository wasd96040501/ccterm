import AgentSDK
import Foundation

/// Pure per-message reveal state + advance math for the streaming
/// "typewriter" effect.
///
/// The SDK delivers assistant text as bursty `text_delta` chunks (several
/// characters at a time, arriving whenever the network flushes). Surfacing
/// each chunk verbatim makes text pop in a block at a time. The mature fix —
/// the same "buffer + drain" pattern ChatGPT-style UIs use — is to decouple
/// the *receive* rate from the *display* rate: accumulate the received text
/// in `target`, and advance a `head` (a fractional character index) toward it
/// a little each frame so the text reveals one glyph at a time.
///
/// One instance tracks the *currently* streaming assistant message. `target`
/// grows as deltas accumulate and is sealed by the finalized `.assistant`
/// envelope (`pendingFinalize`); the head finishing the chase is what drives
/// convergence onto the authoritative message (see `SessionRuntime+Streaming`).
///
/// ### Rate model — "总动画时长一样" (same total duration)
///
/// The reveal must finish ≈ when the stream finishes, never lag long after.
/// Two terms, taken as a max each frame:
///
///   • **exponential catch-up** — close a fixed fraction of the backlog per
///     frame (`remaining / catchUpWindow · dt`). The visible head then trails
///     the received tail by ~`catchUpWindow` seconds and lands ~that long
///     after the last delta — a sub-frame-batch tail, imperceptible against a
///     multi-second response. This term dominates on fast streams.
///   • **a per-second floor** (`minCharsPerSecond`) so a tiny backlog still
///     advances a glyph at a time instead of freezing — the "一个字一个字"
///     feel on slow streams. At 60 char/s this is one glyph per frame at
///     60fps.
///
/// The head can never pass `target.count` (you cannot reveal text that has
/// not been received), so the floor never finishes *before* the stream — on a
/// slow stream it just types each received burst out quickly and then idles at
/// the received boundary until the next delta. Total wall-clock therefore
/// tracks the stream's own cadence.
///
/// No UI, no markdown parsing, no actor isolation — unit-tested in isolation
/// (`TypewriterRevealTests`).
struct TypewriterReveal {

    /// CLI `message.id` this reveal belongs to.
    let messageId: String

    /// Full accumulated text to reveal toward. Grows with `text_delta`s and is
    /// replaced by the authoritative text at finalize.
    var target: String

    /// Fractional character index already revealed. Fractional so a sub-glyph
    /// advance carries across frames instead of rounding to zero.
    var head: Double = 0

    /// The finalized `.assistant` envelope awaiting the head to catch up, plus
    /// the timeline entry id it converges onto. `nil` until the envelope lands;
    /// once set, the head reaching the end of `target` triggers the swap.
    var pendingFinalize: (entryId: UUID, message: Message2)?

    /// Last committed text surfaced to the renderer — lets the driver skip a
    /// redundant re-typeset on a frame where the visible prefix did not move
    /// (e.g. the head advanced into a held-back open code fence).
    var lastSurfaced: String?

    init(messageId: String, target: String = "") {
        self.messageId = messageId
        self.target = target
    }

    /// Whole-character count revealed so far — what the prefix slice uses.
    var revealedCount: Int { min(Int(head), target.count) }

    /// Has the head reached the end of the current `target`?
    var isCaughtUp: Bool { head >= Double(target.count) }

    /// Still has visible reveal work or a deferred finalize to settle.
    var hasWork: Bool { !isCaughtUp || pendingFinalize != nil }

    /// Advance the head one frame toward `target.count` over `dt` seconds.
    mutating func advance(dt: Double, params: Params = .default) {
        let total = Double(target.count)
        let remaining = total - head
        guard remaining > 0, dt > 0 else { return }
        let step = max(
            params.minCharsPerSecond * dt,
            remaining / params.catchUpWindow * dt)
        head = min(head + step, total)
    }

    /// Tuning for the reveal rate.
    struct Params {
        /// Time-constant of the exponential catch-up (seconds). Smaller →
        /// tighter follow / lower tail latency; larger → smoother but laggier.
        var catchUpWindow: Double
        /// Floor reveal speed (characters per second) so a small backlog still
        /// types out one glyph at a time.
        var minCharsPerSecond: Double

        static let `default` = Params(catchUpWindow: 0.12, minCharsPerSecond: 60)
    }
}

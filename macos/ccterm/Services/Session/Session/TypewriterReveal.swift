import AgentSDK
import Foundation

/// Per-message reveal state for the streaming "typewriter" effect. The reveal
/// *rate* is delegated to a `StreamPacer`; this type only carries the
/// message-level envelope state (which message, the accumulated text, the
/// parked finalize) and translates the pacer's unit-agnostic count into a
/// character prefix.
///
/// The SDK delivers assistant text as bursty `text_delta` chunks (several
/// characters at a time, arriving whenever the network flushes). Surfacing each
/// chunk verbatim makes text pop in a block at a time. The fix — the same
/// "buffer + drain" pattern ChatGPT-style UIs use — is to decouple the *receive*
/// rate from the *display* rate: accumulate the received text in `target`, push
/// its length into the pacer, and let the pacer advance a smooth fractional head
/// toward it each frame so the text reveals one glyph at a time.
///
/// One instance tracks the *currently* streaming assistant message. `target`
/// grows as deltas accumulate and is sealed by the finalized `.assistant`
/// envelope (`pendingFinalize`); the head finishing the chase is what drives
/// convergence onto the authoritative message (see `SessionRuntime+Streaming`).
///
/// ### Rate model
///
/// The pacing math lives in `StreamPacer` (EWMA arrival-rate estimate + a
/// first-order servo onto a playout cushion — the standard adaptive-playout /
/// smooth-LLM-token formulation). The visible head trails the received tail by
/// the pacer's playout cushion, advancing at the estimated arrival rate — so the
/// reveal stays smooth across the gaps between deltas instead of racing to each
/// burst boundary and idling. `seal()` (at finalize) drops the cushion so the
/// final tail drains straight to the end.
///
/// No UI, no markdown parsing, no actor isolation — unit-tested in isolation
/// (`TypewriterRevealTests`).
struct TypewriterReveal {

    /// CLI `message.id` this reveal belongs to.
    let messageId: String

    /// Full accumulated text to reveal toward. Grows with `text_delta`s and is
    /// replaced by the authoritative text at finalize. Pushing a new value
    /// updates the pacer's target so a growing target reopens the chase.
    var target: String {
        didSet { pacer.setTarget(Double(target.count)) }
    }

    /// The finalized `.assistant` envelope awaiting the head to catch up, plus
    /// the timeline entry id it converges onto. `nil` until the envelope lands;
    /// once set, the head reaching the end of `target` triggers the swap.
    var pendingFinalize: (entryId: UUID, message: Message2)?

    /// Last committed text surfaced to the renderer — lets the driver skip a
    /// redundant re-typeset on a frame where the visible prefix did not move
    /// (e.g. the head advanced into a held-back open code fence).
    var lastSurfaced: String?

    /// The unit-agnostic pacer that turns the bursty `target.count` into a
    /// smooth fractional reveal head.
    private var pacer: StreamPacer

    init(messageId: String, target: String = "", pacerParams: StreamPacer.Params = .text) {
        self.messageId = messageId
        self.target = target
        self.pacer = StreamPacer(params: pacerParams)
        pacer.setTarget(Double(target.count))
    }

    /// Whole-character count revealed so far — what the prefix slice uses.
    var revealedCount: Int { min(pacer.displayed, target.count) }

    /// Has the head reached the end of the current `target`?
    var isCaughtUp: Bool { revealedCount >= target.count }

    /// Still has visible reveal work or a deferred finalize to settle.
    var hasWork: Bool { !isCaughtUp || pendingFinalize != nil }

    /// Advance the head one frame toward `target.count` over `dt` seconds.
    mutating func advance(dt: Double) {
        pacer.advance(dt: dt)
    }

    /// Seal the reveal for finalize: drop the playout cushion so the head drains
    /// straight to the (now authoritative, no-longer-growing) end.
    mutating func seal() {
        pacer.seal()
    }
}

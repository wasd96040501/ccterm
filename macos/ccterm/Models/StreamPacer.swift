import Foundation

/// Adaptive pacer that decouples a bursty, monotonically-increasing **received**
/// total from a smooth, monotonically-increasing **displayed** total.
///
/// Streaming sources (assistant `text_delta`, the live output-token estimate)
/// arrive in bursts: a clump of units lands when the network flushes, then a
/// gap, then another clump. Surfacing each burst verbatim makes the UI pulse —
/// it races to the received boundary, idles until the next burst, races again.
/// That "type a burst → freeze → type the next burst" cadence is exactly the
/// stutter this type removes.
///
/// ## Algorithm (mature, not ad-hoc)
///
/// Two standard pieces, both with a control-theory basis. The same structure
/// underlies a VoIP adaptive-playout jitter buffer (Ramjee et al., *Adaptive
/// playout mechanisms for packetized audio*) and sebinsua's widely-cited
/// "smooth a stream of LLM tokens" calculator:
///
/// 1. **EWMA arrival-rate estimate.** A continuous-time exponentially-weighted
///    moving average of the arrival rate — the same low-pass filter Jacobson's
///    TCP RTT estimator (RFC 6298) uses:
///
///        r̂ ← r̂ + α·(sample − r̂),   α = 1 − e^(−dt / τ_rate)
///
///    The `dt`-dependent `α` makes `τ_rate` a real time-constant, independent of
///    frame rate, so the estimate behaves identically at 60fps or 120fps.
///
/// 2. **First-order servo with rate feed-forward.** The display velocity is the
///    estimated arrival rate (feed-forward) plus a proportional correction that
///    drives the backlog toward a small cushion:
///
///        cushion = r̂ · targetLatency           (jitter-buffer playout delay)
///        v       = r̂ + (backlog − cushion) / τ_catchUp,   clamped to [0, maxRate]
///        emitted = min(emitted + v·dt, target)  (never reveal unreceived units)
///
///    More backlog ⇒ faster drain (sebinsua's linear delay-vs-queue law, and a
///    VoIP playout deadline). The cushion is a *time* cushion — units worth of
///    `targetLatency` seconds at the current rate — so it scales with the
///    stream: fast streams hold a larger buffer, slow streams a smaller one.
///
/// ## No speed floor — the velocity is fully data-driven
///
/// The velocity is clamped to `[0, maxRate]`, **not** `[minRate, maxRate]`. The
/// upper bound stops a single huge burst from teleporting; the lower bound is
/// **0** — "no data ⇒ no advance". A non-zero floor (a fixed minimum char/s) is
/// what breaks pacing: when the arrival rate falls *below* it — a slow CJK reply
/// at ~40 char/s under a 60 char/s floor — the floor forces the display to
/// outrun the arrivals, drain the buffer to empty, and stall at the boundary
/// every few frames. With a 0 floor the steady-state velocity simply settles to
/// the arrival rate (`v = r̂`, `backlog = cushion`): the display trails by a
/// fixed playout delay and never catches the boundary, so it never stutters.
///
/// Two **boundary conditions** replace what a floor used to (mis)handle — both
/// one-shot edges, not a sustained rule on the velocity:
///
///   • **End snap.** A first-order drain approaches `target` asymptotically and
///     never quite reaches it, so `isCaughtUp` would never fire. Once the
///     backlog falls within `snapEpsilon`, jump `emitted` to `target`. This is
///     what makes the reveal converge once the stream ends (the rate decays, the
///     cushion shrinks to 0, the backlog drains into `snapEpsilon`).
///   • **First-unit kick.** The instant any unit has arrived, surface at least
///     the first one (`emitted` lifted to 1 while it is still < 1) so a
///     provisional entry exists from frame one — a finalized envelope for a
///     3-char reply can land in the same runloop batch as its first delta.
///
/// First-order ⇒ unconditionally stable, no overshoot oscillation.
///
/// ## Generic over the unit
///
/// The unit is whatever the caller counts: characters for the typewriter
/// reveal, tokens for the live usage counter. No UI, no markdown, no actor
/// isolation, no `Foundation` beyond `exp` — unit-tested in isolation
/// (`StreamPacerTests`).
struct StreamPacer {

    /// Tuning for one pacing channel. Time-constants are in seconds; rates in
    /// units per second.
    struct Params: Equatable {
        /// Time-constant of the arrival-rate low-pass filter. Larger → steadier
        /// estimate, slower to react to a rate change.
        var rateTimeConstant: Double
        /// Time-constant of the backlog-correction servo. Smaller → tighter
        /// catch-up onto the cushion.
        var catchUpTimeConstant: Double
        /// Playout delay (seconds): the display trails the receive boundary by
        /// this much content at the current rate (`cushion = r̂ · targetLatency`).
        /// Must exceed the typical inter-burst gap to fully hide it.
        var targetLatency: Double
        /// Ceiling display rate (units/sec) so a single huge burst reveals
        /// quickly but never teleports. There is no floor — see the type doc.
        var maxRate: Double

        /// Characters. `targetLatency` is sized off the **measured** SSE cadence
        /// (a `claude-haiku` long-story turn via `PartialMessagesSmoke`):
        /// ~17-char chunks arriving a median 228ms apart (p90 281ms). A cushion
        /// must bridge that gap or the display drains between chunks and stutters
        /// a chunk (~1/3 line) at a time; 0.3s ⇒ ~23-char cushion at that rate,
        /// just over one chunk. The cap keeps a giant paste-in from teleporting.
        static let text = Params(
            rateTimeConstant: 0.35,
            catchUpTimeConstant: 0.25,
            targetLatency: 0.3,
            maxRate: 700)

        /// Token counters: a smooth, readable climb between the CLI's coarse
        /// estimate jumps (+50, +700, …) instead of a snap. Resolves a large
        /// final-reconcile jump within ~1s.
        static let counter = Params(
            rateTimeConstant: 0.4,
            catchUpTimeConstant: 0.25,
            targetLatency: 0.2,
            maxRate: 2000)
    }

    /// Backlog (units) within which the display snaps to target — the end
    /// boundary that makes a first-order drain actually reach `target`.
    private static let snapEpsilon = 0.5

    private let params: Params

    /// Absolute received total — what the display is chasing.
    private(set) var target: Double = 0
    /// Fractional displayed total. Fractional so a sub-unit advance carries
    /// across frames instead of rounding to zero.
    private(set) var emitted: Double = 0
    /// EWMA estimate of the arrival rate (units/sec).
    private(set) var rate: Double = 0
    /// `target` at the previous `advance` — the per-frame growth sample source.
    private var lastTarget: Double = 0
    /// Once sealed, the cushion is dropped so the display drains all the way to
    /// target (the stream is known to have ended).
    private var sealed = false

    init(params: Params = .text) {
        self.params = params
    }

    // MARK: - Input

    /// Set the absolute received total. **Monotonic** — a value below the
    /// current target is ignored (a stale / duplicate report), so the display
    /// never snaps backward.
    mutating func setTarget(_ total: Double) {
        if total > target { target = total }
    }

    /// Seal the stream: no more arrivals are expected, so drop the cushion and
    /// let the display drain straight to `target`. Used at finalize.
    mutating func seal() { sealed = true }

    /// Hard-jump the display to the current target (no roll). Resets the rate
    /// estimate so a later resumption starts cleanly.
    mutating func snap() {
        emitted = target
        lastTarget = target
        rate = 0
    }

    // MARK: - Output

    /// Whole units to show now.
    var displayed: Int { Int(emitted) }
    /// Fractional displayed total (for callers that interpolate further).
    var displayedExact: Double { emitted }
    /// Units received but not yet displayed.
    var backlog: Double { max(0, target - emitted) }
    /// Current EWMA arrival-rate estimate (units/sec) — exposed for tests/debug.
    var estimatedRate: Double { rate }
    /// Has the display reached the received boundary?
    var isCaughtUp: Bool { emitted >= target }
    /// Still has units to reveal.
    var hasBacklog: Bool { emitted < target }

    // MARK: - Step

    /// Advance the display by `dt` seconds: refresh the rate estimate from this
    /// frame's arrival sample, then integrate the servo velocity. Returns the
    /// whole-unit count now visible.
    @discardableResult
    mutating func advance(dt: Double) -> Int {
        guard dt > 0 else { return displayed }

        // 1. EWMA rate estimate from this frame's arrival sample. Monotonic
        //    target ⇒ a non-negative sample; a paused stream feeds 0 and the
        //    estimate decays toward 0.
        let grew = max(0, target - lastTarget)
        lastTarget = target
        let sample = grew / dt
        let alpha = 1 - exp(-dt / params.rateTimeConstant)
        rate += alpha * (sample - rate)

        // 2. First-order servo: feed-forward rate + proportional backlog term,
        //    targeting a rate-scaled playout cushion. Sealed ⇒ no cushion. The
        //    velocity is data-driven with a 0 floor — see the type doc on why a
        //    non-zero floor is what stutters a slow stream.
        let cushion = sealed ? 0 : rate * params.targetLatency
        var velocity = rate + (backlog - cushion) / params.catchUpTimeConstant
        velocity = min(max(velocity, 0), params.maxRate)

        // 3. Integrate and clamp — you cannot reveal units that have not arrived.
        emitted = min(emitted + velocity * dt, target)

        // 4. Boundary conditions (one-shot edges, not a sustained floor):
        //    • end snap — a first-order drain never quite reaches target, so
        //      pull it in once it is within snapEpsilon (makes `isCaughtUp`
        //      reachable when the stream ends and the backlog drains);
        //    • first-unit kick — surface the first unit the instant any content
        //      has arrived, so the provisional entry exists from frame one.
        if backlog < Self.snapEpsilon {
            emitted = target
        } else if emitted < 1 {
            emitted = 1
        }
        return displayed
    }
}

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
///        v       = r̂ + (backlog − cushion) / τ_catchUp,   clamped to [minRate, maxRate]
///        emitted = min(emitted + v·dt, target)  (never reveal unreceived units)
///
///    More backlog ⇒ faster drain (sebinsua's linear delay-vs-queue law, and a
///    VoIP playout deadline). The cushion is a *time* cushion — units worth of
///    `targetLatency` seconds at the current rate — so it scales with the
///    stream: fast streams hold a larger buffer, slow streams a smaller one,
///    matching the adaptive-playout formulation.
///
/// ## Why it doesn't stutter, yet still converges
///
/// At a steady arrival rate `r` the loop settles to `v = r` and
/// `backlog = cushion`: the display trails the receive boundary by a constant
/// `targetLatency` seconds of content and advances at exactly the arrival rate —
/// smooth, no idle. When arrivals pause for less than `targetLatency`, the
/// feed-forward keeps draining the cushion, so the display keeps moving across
/// the gap instead of freezing. When the stream truly ends (`target` stops
/// growing), the `minRate` floor always carries `emitted` the last cushion-worth
/// up to `target`, so `isCaughtUp` is reachable — `seal()` drops the cushion to
/// drain that tail promptly. A first-order system is unconditionally stable, so
/// there is no overshoot oscillation.
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
        /// Floor display rate (units/sec) so a tiny backlog still advances and
        /// the tail always converges onto `target`.
        var minRate: Double
        /// Ceiling display rate (units/sec) so a single huge burst reveals
        /// quickly but never teleports.
        var maxRate: Double

        /// Characters: snappy, ~one glyph/frame floor, sized to hide the
        /// ~50–120ms gaps between SSE `text_delta` flushes.
        static let text = Params(
            rateTimeConstant: 0.25,
            catchUpTimeConstant: 0.18,
            targetLatency: 0.12,
            minRate: 60,
            maxRate: 700)

        /// Token counters: a smooth, readable climb between the CLI's coarse
        /// estimate jumps (+50, +700, …) instead of a snap. Resolves a large
        /// final-reconcile jump within ~1s.
        static let counter = Params(
            rateTimeConstant: 0.4,
            catchUpTimeConstant: 0.25,
            targetLatency: 0.2,
            minRate: 8,
            maxRate: 2000)
    }

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
    /// Once sealed, the cushion is dropped so the display drains fully to target.
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
        //    targeting a rate-scaled playout cushion. Sealed ⇒ no cushion.
        let cushion = sealed ? 0 : rate * params.targetLatency
        var velocity = rate + (backlog - cushion) / params.catchUpTimeConstant
        velocity = min(max(velocity, params.minRate), params.maxRate)

        // 3. Integrate and clamp — you cannot reveal units that have not arrived.
        emitted = min(emitted + velocity * dt, target)
        return displayed
    }
}

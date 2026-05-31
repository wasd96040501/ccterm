import Foundation

/// Adaptive pacer that decouples a bursty, monotonically-increasing **received**
/// total from a smooth, monotonically-increasing **displayed** total — smooth not
/// just in *position* (no freeze) but in *velocity* (no rate jitter).
///
/// Streaming sources (assistant `text_delta`, the live output-token estimate)
/// arrive in bursts: a clump of units lands when the network flushes, then a
/// gap, then another clump. Surfacing each burst verbatim makes the UI pulse —
/// it races to the received boundary, idles until the next burst, races again.
///
/// A first-order pacer fixes the *freeze* (the display trails by a playout
/// cushion and never catches the boundary) but **not** the *rate jitter*: its
/// velocity is recomputed from scratch each frame as
/// `v = r̂ + (backlog − cushion)/τ`, and both terms step-jump the instant a burst
/// lands (`backlog` jumps by the chunk size; `r̂` jumps as the EWMA re-rises).
/// So `emitted(t)` is C⁰ (continuous position) but `v(t) = d(emitted)/dt` is
/// **discontinuous** — the reveal visibly speeds up at each burst and coasts down
/// in the gap. That residual "typing speed wobble" is what this type removes.
///
/// ## Algorithm — a critically-damped second-order servo (rate jitter ⇒ smooth)
///
/// The display **velocity is a state variable**, not a per-frame recomputation.
/// It is driven by an acceleration command, so velocity is the integral of a
/// (bounded) acceleration and is therefore continuous: C⁰ velocity ⇒ C¹ position.
/// The same structure underlies Unity's `SmoothDamp` / Game Programming Gems 4
/// "Critically Damped Smoothing", and the α-β tracking filter used in radar:
///
/// 1. **EWMA arrival-rate estimate** (unchanged) — a continuous-time
///    exponentially-weighted moving average, the low-pass filter Jacobson's TCP
///    RTT estimator (RFC 6298) uses:
///
///        r̂ ← r̂ + α·(sample − r̂),   α = 1 − e^(−dt / τ_rate)
///
///    `r̂` is the **feed-forward prediction** of the near-future arrival rate
///    (a level-only / constant-rate forecast — see "Predicting the rate").
///
/// 2. **Critically-damped second-order servo with rate feed-forward.** The
///    display position `E` chases a reference that trails the receive boundary by
///    a playout cushion, and the display velocity `v = Ė` is pulled toward the
///    predicted arrival rate `r̂`:
///
///        cushion = r̂ · targetLatency             (jitter-buffer playout delay)
///        ref     = target − cushion               (where the head should sit)
///        a = ω²·(ref − E) + 2ω·(r̂ − v),   ω = 1/τ_follow
///        v ← max(v + a·dt, 0)                     (velocity is a *state*)
///        E ← min(E + v·dt, target)                (never reveal unreceived units)
///
///    With the position gain `ω²` and velocity gain `2ω`, the error dynamics are
///    `p̈ + 2ω·ṗ + ω²·p = 0`, i.e. `(s + ω)² = 0` — a **double real root**, the
///    definition of **critical damping**: fastest approach with *no overshoot and
///    no oscillation*. In steady state `E = target − cushion` and `v = r̂`: the
///    head trails by a fixed playout delay and moves at the arrival rate, so the
///    velocity is smooth and never catches the boundary.
///
///    The acceleration `a` still step-jumps when a burst lands (the position
///    error jumps by the chunk size), but `a` is *integrated* into `v`, so the
///    **velocity only changes by `a·dt` per frame** — a small, continuous nudge
///    (≈ ω²·chunk·dt, single digits) instead of the first-order law's whole
///    `chunk/τ` jump (tens). That is the C⁰→C¹ upgrade the eye reads as smooth.
///
/// ## Predicting the rate from history
///
/// The feed-forward `r̂` is a **level-only (zeroth-order) forecast**: it predicts
/// the future arrival rate as the current EWMA-smoothed rate (a constant-rate /
/// random-walk model — the same one-step-ahead forecast simple exponential
/// smoothing produces). It carries no explicit trend term, so it lags a ramping
/// rate. What genuinely "carries recent rate forward" here is the **velocity
/// state `v` itself**: like the α-β filter's velocity estimate, it has inertia —
/// it can only change through a bounded acceleration — so the display keeps
/// moving at the recent rate through a gap instead of snapping to each burst.
/// (A trend-aware predictor — Holt's double exponential smoothing, or the α-β-γ
/// filter's acceleration term — would extrapolate a *changing* rate; it is not
/// needed for the current cadence and is left out to keep the servo provably
/// non-overshooting.)
///
/// ## Stability of the discrete integration
///
/// Semi-implicit (symplectic) Euler — `v` updated before `E` — is stable for a
/// critically-damped spring while `ω·dt < 2`. At 60fps with `ω ≈ 5` that is
/// `0.08 ≪ 2`, with a wide margin; but a stalled main thread can hand `advance`
/// a large `dt`. To stay stable *and* frame-rate independent regardless of frame
/// hitches, the servo integration is **sub-stepped** at ≤ `maxSubStep` seconds
/// (the EWMA still updates once per `advance`, so its semantics are unchanged).
///
/// ## No floor, and no ceiling either — the velocity is fully data-driven
///
/// `v` is clamped only at the bottom, to **0** ("no data ⇒ no advance"), and is
/// unbounded above. A non-zero floor would force the display to outrun a slow
/// stream, drain the buffer, and stall at the boundary; with a 0 floor the servo
/// simply settles to the arrival rate and trails by the playout delay.
///
/// No ceiling is needed because the velocity is a **state** that starts at 0 and
/// can only change through a bounded acceleration `a·dt` — so a single huge burst
/// physically *cannot* teleport in one frame, it has to ramp the velocity up over
/// several frames first (and `E = min(…, target)` clamps it to the boundary
/// throughout). The reveal speed for a big burst is self-limited by the servo's
/// acceleration, not by an external cap. A first-order pacer *did* need a `maxRate`
/// cap — there `v` was recomputed instantaneously each frame and a big backlog
/// produced an arbitrarily large single-frame jump — but that same cap then
/// throttled a large finalize to a crawl (a 10k-char message draining at the cap
/// would take many seconds); dropping it lets big bursts converge in ~1s.
///
/// Two **boundary conditions** (one-shot edges, not a sustained rule):
///
///   • **End snap.** A second-order drain approaches `target` asymptotically;
///     once the backlog falls within `snapEpsilon`, jump `E` to `target` so
///     `isCaughtUp` actually fires when the stream ends (the rate decays, the
///     cushion shrinks to 0, the backlog drains into `snapEpsilon`).
///   • **First-unit kick.** The instant any unit has arrived, surface at least
///     the first one (`E` lifted to 1 while still < 1) so a provisional entry
///     exists from frame one — the servo's velocity ramps up from 0, so without
///     the kick the very first glyph would lag a few frames.
///
/// ## Generic over the unit
///
/// The unit is whatever the caller counts: characters for the typewriter reveal,
/// tokens for the live usage counter. No UI, no markdown, no actor isolation, no
/// `Foundation` beyond `exp` — unit-tested in isolation (`StreamPacerTests`).
struct StreamPacer {

    /// Tuning for one pacing channel. Time-constants are in seconds; rates in
    /// units per second.
    struct Params: Equatable {
        /// Time-constant of the arrival-rate low-pass filter. Larger → steadier
        /// estimate, slower to react to a rate change.
        var rateTimeConstant: Double
        /// Natural time-constant of the second-order servo (`ω = 1/τ_follow`).
        /// Larger → smoother velocity (more low-pass of the burst cadence) but
        /// more display lag and slower catch-up; smaller → tighter tracking but
        /// the per-burst velocity nudge grows. Critically damped at any value.
        var followTimeConstant: Double
        /// Playout delay (seconds): the display trails the receive boundary by
        /// this much content at the current rate (`cushion = r̂ · targetLatency`).
        /// Must exceed the typical inter-burst gap to fully hide it.
        var targetLatency: Double

        /// Characters. Tuned against the **measured** SSE cadence (a
        /// `claude-haiku` long-story turn via `PartialMessagesSmoke`): ~17-char
        /// chunks arriving a median 228ms apart (p90 281ms), with 674/416/439ms
        /// outliers. Two coupled constraints, verified by replaying the trace:
        ///   • `targetLatency` (cushion) must bridge the worst gap *and* absorb
        ///     the servo's velocity momentum coasting into the boundary during a
        ///     long quiet gap — `0.5s` keeps the buffer non-empty across the 674ms
        ///     outlier (a smaller cushion that sufficed for the first-order law
        ///     runs dry under the momentum servo);
        ///   • `followTimeConstant` (`ω = 1/0.3 ≈ 3.3 rad/s`) low-passes the
        ///     ~4–5Hz burst cadence so the velocity barely ripples (max per-frame
        ///     change ≈ 9 char/s vs the first-order law's ~98), while still
        ///     chasing a 400-char batch down in < 1s.
        static let text = Params(
            rateTimeConstant: 0.7,
            followTimeConstant: 0.3,
            targetLatency: 0.5)

        /// Token counters: a smooth, readable climb between the CLI's coarse
        /// estimate jumps (+50, +700, …) instead of a snap. A smaller cushion than
        /// the text reveal (the counter has no "freeze between glyphs" failure
        /// mode) and resolves a large final-reconcile jump within ~1s.
        static let counter = Params(
            rateTimeConstant: 0.5,
            followTimeConstant: 0.25,
            targetLatency: 0.2)
    }

    /// Backlog (units) within which the display snaps to target — the end
    /// boundary that makes a second-order drain actually reach `target`.
    private static let snapEpsilon = 0.5

    /// Servo integration is sub-stepped at no more than this many seconds per
    /// step, so explicit integration stays stable and frame-rate independent even
    /// when a frame hitch hands `advance` a large `dt` (see the type doc).
    private static let maxSubStep = 1.0 / 120.0

    private let params: Params

    /// Absolute received total — what the display is chasing.
    private(set) var target: Double = 0
    /// Fractional displayed total. Fractional so a sub-unit advance carries
    /// across frames instead of rounding to zero.
    private(set) var emitted: Double = 0
    /// Display **velocity** (units/sec) — a servo state, integrated from the
    /// acceleration command. Carrying it across frames is what makes the velocity
    /// (the typing rate) continuous rather than recomputed-and-jumping each frame.
    private(set) var velocity: Double = 0
    /// EWMA estimate of the arrival rate (units/sec) — the feed-forward forecast.
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

    /// Hard-jump the display to the current target (no roll). Resets the rate and
    /// velocity so a later resumption starts cleanly.
    mutating func snap() {
        emitted = target
        lastTarget = target
        velocity = 0
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
    /// Current display velocity (units/sec) — exposed for tests/debug.
    var displayVelocity: Double { velocity }
    /// Has the display reached the received boundary?
    var isCaughtUp: Bool { emitted >= target }
    /// Still has units to reveal.
    var hasBacklog: Bool { emitted < target }

    // MARK: - Step

    /// Advance the display by `dt` seconds: refresh the rate estimate from this
    /// frame's arrival sample, then integrate the critically-damped servo (the
    /// velocity is a state, so the displayed rate changes smoothly). Returns the
    /// whole-unit count now visible.
    @discardableResult
    mutating func advance(dt: Double) -> Int {
        guard dt > 0 else { return displayed }

        // 1. EWMA rate estimate from this frame's arrival sample. Monotonic
        //    target ⇒ a non-negative sample; a paused stream feeds 0 and the
        //    estimate decays toward 0. Updated once per `advance` (the servo
        //    below sub-steps, but the rate sample is whole-frame).
        let grew = max(0, target - lastTarget)
        lastTarget = target
        let sample = grew / dt
        let alpha = 1 - exp(-dt / params.rateTimeConstant)
        rate += alpha * (sample - rate)

        // 2. Reference the head should sit at and the velocity it should hold.
        //    The feed-forward velocity is the estimated rate in *both* phases:
        //    sealing only drops the cushion (ref → target) so the tail drains all
        //    the way in, but the head keeps coasting at the last known rate so a
        //    sealed drain is no slower than an un-sealed one (it would be, if the
        //    feed-forward were zeroed and only the position spring drove the end).
        let cushion = sealed ? 0 : rate * params.targetLatency
        let ref = target - cushion
        let refVel = rate
        let omega = 1 / params.followTimeConstant

        // 3. Critically-damped second-order servo, sub-stepped for stability.
        //    `a = ω²·(ref − E) + 2ω·(refVel − v)` ⇒ error dynamics `(s+ω)²` —
        //    no overshoot, no oscillation. `v` is a state ⇒ continuous velocity.
        //    Floored at 0 (never un-reveal), no ceiling: the velocity-state
        //    inertia already stops a one-frame teleport (see the type doc).
        var remaining = dt
        while remaining > 1e-12 {
            let h = min(remaining, Self.maxSubStep)
            remaining -= h
            let accel = omega * omega * (ref - emitted) + 2 * omega * (refVel - velocity)
            velocity = max(velocity + accel * h, 0)
            emitted = min(emitted + velocity * h, target)
        }

        // 4. Boundary conditions (one-shot edges, not a sustained floor):
        //    • end snap — a second-order drain never quite reaches target, so
        //      pull it in once within snapEpsilon (makes `isCaughtUp` reachable
        //      when the stream ends and the backlog drains);
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

import XCTest

@testable import ccterm

/// Pure tests for `StreamPacer` — the EWMA-rate-estimating, critically-damped
/// second-order servo that decouples a bursty received total from a smooth
/// displayed total. No UI, no ticker; the pacer is stepped by hand at a fixed
/// 60fps `dt`.
///
/// These prove the properties the design promises:
///   • **position** is smooth — it never overshoots the boundary, never stutters
///     between bursts, catches up when it falls behind, always converges;
///   • **velocity** is smooth too — the *typing rate* changes continuously (no
///     per-frame speed jump at each burst), it ramps up/down without oscillation
///     (critically damped), and the velocity is dramatically steadier than the
///     first-order law it replaces (`testVelocityIsSmoothUnderRealCadence`).
final class StreamPacerTests: XCTestCase {

    private let frame = 1.0 / 60.0

    /// (chars, gapMsFromPrevDelta) — verbatim from a `claude-haiku` long-story
    /// turn (`PartialMessagesSmoke`): ~17-char chunks arriving a median 228ms
    /// apart (p90 281ms, with 674/416/439ms outliers), ~77 chars/s mean. The
    /// fixture both the dry-buffer proof and the velocity-smoothness proof replay.
    static let haikuTrace: [(len: Int, gap: Double)] = [
        (17, 0), (20, 267), (15, 206), (17, 262), (18, 213), (18, 211), (15, 210),
        (11, 237), (13, 234), (22, 238), (14, 212), (22, 237), (22, 235), (12, 211),
        (18, 217), (11, 228), (16, 211), (10, 235), (21, 238), (15, 262), (16, 210),
        (13, 315), (13, 210), (9, 242), (22, 674), (14, 4), (16, 1), (18, 256),
        (17, 301), (15, 158), (23, 149), (21, 215), (14, 416), (12, 57), (23, 439),
        (20, 112), (21, 298), (22, 156), (18, 232), (17, 242), (14, 321), (24, 226),
    ]

    /// Replay `haikuTrace` frame by frame at 60fps. `onFrame` is called *after*
    /// each `advance` with the post-advance pacer (by value), the frame index,
    /// and whether more deltas are still owed (the stream hasn't ended). A +2s
    /// tail lets the reveal drain.
    private func replayHaiku(
        params: StreamPacer.Params = .text,
        _ onFrame: (_ pacer: StreamPacer, _ frame: Int, _ owedMore: Bool) -> Void
    ) {
        var arrival: [Double] = []
        var clock = 0.0
        for d in Self.haikuTrace {
            clock += d.gap
            arrival.append(clock)
        }
        let lastArrival = arrival.last ?? 0

        var pacer = StreamPacer(params: params)
        var target = 0.0
        var next = 0
        var simMs = 0.0
        let frameMs = 1000.0 / 60.0
        var f = 0
        while simMs <= lastArrival + 2000 {
            simMs += frameMs
            while next < Self.haikuTrace.count, arrival[next] <= simMs {
                target += Double(Self.haikuTrace[next].len)
                pacer.setTarget(target)
                next += 1
            }
            pacer.advance(dt: frameMs / 1000)
            onFrame(pacer, f, next < Self.haikuTrace.count)
            f += 1
        }
    }

    // MARK: - Invariants

    /// You can never display units that have not arrived: `emitted ≤ target`
    /// every frame, under an arbitrary bursty schedule.
    func testNeverOvershootsTheReceivedBoundary() {
        var pacer = StreamPacer(params: .text)
        var target = 0.0
        for f in 0..<600 {
            if f % 4 == 0 {
                target += 9
                pacer.setTarget(target)
            }
            pacer.advance(dt: frame)
            XCTAssertLessThanOrEqual(
                pacer.displayedExact, pacer.target + 1e-9,
                "frame \(f): displayed \(pacer.displayedExact) passed target \(pacer.target)")
        }
    }

    /// A stale / duplicate report below the current target is ignored — the
    /// display never snaps backward.
    func testTargetIsMonotonic() {
        var pacer = StreamPacer(params: .text)
        pacer.setTarget(100)
        XCTAssertEqual(pacer.target, 100)
        pacer.setTarget(40)  // stale
        XCTAssertEqual(pacer.target, 100, "a smaller target must be ignored")
    }

    func testZeroDtAndEmptyTargetAreNoops() {
        var pacer = StreamPacer(params: .text)
        XCTAssertEqual(pacer.advance(dt: 0), 0)
        XCTAssertTrue(pacer.isCaughtUp)
        pacer.setTarget(0)
        XCTAssertEqual(pacer.advance(dt: frame), 0)
        XCTAssertTrue(pacer.isCaughtUp)
        XCTAssertFalse(pacer.hasBacklog)
    }

    // MARK: - The bug: no stutter between bursts

    /// The anti-stutter proof for the **fast** regime, where the arrival rate
    /// (144 units/s here) sits *above* `minRate` so the floor never binds. This
    /// is necessary but NOT sufficient — it does not exercise the slow regime
    /// where the floor would wrongly force the display to outrun the arrivals
    /// (see `testSlowStreamBelowFloorDoesNotStallAtBoundary`).
    ///
    /// Once the loop reaches steady state the display must:
    ///   1. **never freeze** — every frame advances (`Δemitted > 0`);
    ///   2. **never drain to the boundary mid-stream** — the playout cushion
    ///      keeps a backlog, so the display never idles waiting for the next
    ///      burst;
    ///   3. **advance smoothly** — the per-frame step stays in a tight band
    ///      instead of swinging between a fast catch-up and a floor crawl (the
    ///      old `max(floor, backlog/window)` behaviour).
    func testSteadyBurstyStreamDoesNotStutter() {
        var pacer = StreamPacer(params: .text)
        var target = 0.0
        // 12 units every 5 frames ≈ 144 units/s, with an 83ms inter-burst gap
        // (longer than one frame) — the schedule that makes a naive reveal pulse.
        let burstEvery = 5
        let burstSize = 12.0

        var lastEmitted = 0.0
        var steadySteps: [Double] = []
        var minBacklogSteady = Double.greatestFiniteMagnitude

        for f in 0..<240 {
            if f % burstEvery == 0 {
                target += burstSize
                pacer.setTarget(target)
            }
            pacer.advance(dt: frame)
            let step = pacer.displayedExact - lastEmitted
            lastEmitted = pacer.displayedExact

            // Sample steady state only (skip the EWMA warm-up).
            if f >= 90 {
                steadySteps.append(step)
                minBacklogSteady = min(minBacklogSteady, pacer.backlog)
            }
        }

        // 1. Never freezes.
        let minStep = steadySteps.min() ?? 0
        XCTAssertGreaterThan(
            minStep, 0.2,
            "the reveal froze on some frame (min step \(minStep)) — that is the stutter")

        // 2. Never drains to the boundary while data is still arriving.
        XCTAssertGreaterThan(
            minBacklogSteady, 2,
            "the cushion collapsed (min backlog \(minBacklogSteady)) — display idled at the boundary")

        // 3. Smooth: the fastest frame is at most ~2× the slowest. (The old
        //    floor-vs-catch-up model swings far wider than this.)
        let maxStep = steadySteps.max() ?? 0
        XCTAssertLessThan(
            maxStep / minStep, 2.2,
            "per-frame step swung too much (\(minStep)…\(maxStep)) — not smooth")
    }

    /// The regime the fast test misses: an arrival rate **below** what a fixed
    /// speed floor would impose (a ~40 char/s CJK reply; the old `minRate` was
    /// 60 char/s). A floor here forces the display to outrun the arrivals, so the
    /// buffer drains to empty and the display stalls at the boundary every few
    /// frames. We probe that directly by counting frames where the buffer has
    /// **run dry** mid-stream — the drain events that ARE the stutter. With a
    /// data-driven (0-floor) velocity the buffer never empties, so the count is 0.
    func testSlowStreamBelowFloorDoesNotStallAtBoundary() {
        var pacer = StreamPacer(params: .text)
        var target = 0.0
        // 2 units every 3 frames = 40 units/s — below a 60-unit/s floor.
        var dryFrames = 0
        var drainEvents = 0
        var wasDry = false

        for f in 0..<900 {
            if f % 3 == 0 {
                target += 2
                pacer.setTarget(target)
            }
            pacer.advance(dt: frame)
            // Steady state only (after the EWMA warm-up).
            guard f >= 180 else { continue }
            let dry = pacer.backlog < 0.5
            if dry {
                dryFrames += 1
                if !wasDry { drainEvents += 1 }  // a fresh buffer-empty edge
            }
            wasDry = dry
        }

        XCTAssertEqual(
            drainEvents, 0,
            "buffer ran dry \(drainEvents) time(s) (\(dryFrames) frames) mid-stream — "
                + "the display stalled at the boundary, i.e. the stutter")
    }

    /// Replays the **real** SSE cadence (see `haikuTrace`). With the cushion too
    /// small to bridge a 228ms gap, the display catches the boundary between
    /// chunks and the buffer runs dry — the "1/3-line stutter". We replay the
    /// trace frame by frame and count dry frames (buffer empty while more deltas
    /// are still owed).
    func testRealHaikuCadenceKeepsTheBufferFull() {
        var dryFrames = 0
        replayHaiku { pacer, f, owedMore in
            // A dry buffer while deltas are still owed is a mid-stream stall.
            if f > 30, owedMore, pacer.backlog < 0.5 { dryFrames += 1 }
        }
        XCTAssertEqual(
            dryFrames, 0,
            "the buffer ran dry on \(dryFrames) frame(s) under the real 228ms-median "
                + "cadence — the display stalled between chunks (the 1/3-line stutter)")
    }

    // MARK: - Catch up when it falls behind

    /// A large sudden jump (a slow stream that abruptly bursts, or a batched
    /// flush) must be chased down: the display accelerates and the backlog
    /// returns toward the cushion within a bounded time, without ever passing
    /// target.
    func testLargeJumpIsChasedDownQuickly() {
        var pacer = StreamPacer(params: .text)
        // Settle at a modest steady rate first.
        var target = 0.0
        for f in 0..<120 {
            if f % 6 == 0 {
                target += 6
                pacer.setTarget(target)
            }
            pacer.advance(dt: frame)
        }
        let backlogBefore = pacer.backlog

        // A 400-unit batch lands at once.
        target += 400
        pacer.setTarget(target)

        // Within ~1s the backlog must shrink back near its steady cushion — the
        // servo's proportional term drains the surplus.
        var frames = 0
        while pacer.backlog > backlogBefore + 30, frames < 90 {
            pacer.advance(dt: frame)
            frames += 1
            XCTAssertLessThanOrEqual(pacer.displayedExact, pacer.target + 1e-9)
        }
        XCTAssertLessThan(frames, 90, "the 400-unit surplus was not chased down within 1.5s")
    }

    // MARK: - Throttle: never teleport

    /// A single huge burst with nothing after it must still reveal over many
    /// frames, not pop in at once — and then converge. There is no `maxRate`
    /// cap; the throttle is the velocity *state* itself, which starts at 0 and
    /// can only ramp up through bounded acceleration, so the first frame reveals
    /// only a sliver however large the burst.
    func testSingleHugeBurstRevealsGraduallyThenConverges() {
        var pacer = StreamPacer(params: .text)
        pacer.setTarget(1000)

        let afterOneFrame = pacer.advance(dt: frame)
        XCTAssertGreaterThan(afterOneFrame, 0, "must start revealing immediately")
        XCTAssertLessThan(afterOneFrame, 20, "must not teleport the whole 1000-unit burst in one frame")

        var frames = 1
        while pacer.hasBacklog, frames < 600 {
            pacer.advance(dt: frame)
            frames += 1
        }
        XCTAssertTrue(pacer.isCaughtUp, "a fully-received target must converge")
    }

    // MARK: - Convergence

    /// Once the stream ends, the rate decays, the cushion shrinks to 0, and the
    /// backlog drains into `snapEpsilon` to converge. `seal()` (finalize) drops
    /// the cushion immediately so that tail drains at least as fast.
    func testSealDrainsTheTailFasterThanUnsealed() {
        func framesToCaughtUp(sealed: Bool) -> Int {
            var pacer = StreamPacer(params: .text)
            // Build a real rate so a cushion exists, then stop feeding.
            var target = 0.0
            for f in 0..<120 {
                if f % 4 == 0 {
                    target += 10
                    pacer.setTarget(target)
                }
                pacer.advance(dt: frame)
            }
            if sealed { pacer.seal() }
            var frames = 0
            while pacer.hasBacklog, frames < 600 {
                pacer.advance(dt: frame)
                frames += 1
            }
            XCTAssertTrue(pacer.isCaughtUp)
            return frames
        }
        let sealedFrames = framesToCaughtUp(sealed: true)
        let unsealedFrames = framesToCaughtUp(sealed: false)
        XCTAssertLessThanOrEqual(
            sealedFrames, unsealedFrames,
            "sealing must not be slower than letting the floor drain the cushion")
    }

    func testSnapJumpsToTarget() {
        var pacer = StreamPacer(params: .text)
        pacer.setTarget(500)
        pacer.advance(dt: frame)
        XCTAssertLessThan(pacer.displayedExact, 500)
        pacer.snap()
        XCTAssertEqual(pacer.displayedExact, 500)
        XCTAssertTrue(pacer.isCaughtUp)
    }

    // MARK: - EWMA rate estimate

    /// Fed a steady arrival rate, the EWMA estimate converges near the true
    /// rate (this is what the feed-forward term relies on).
    func testRateEstimateConvergesToTrueArrivalRate() {
        var pacer = StreamPacer(params: .text)
        var target = 0.0
        // Exactly 2 units/frame = 120 units/s.
        for _ in 0..<300 {
            target += 2
            pacer.setTarget(target)
            pacer.advance(dt: frame)
        }
        XCTAssertEqual(
            pacer.estimatedRate, 120, accuracy: 12,
            "EWMA rate estimate should track the 120 units/s arrival rate")
    }

    // MARK: - Token counter: continuous 1,2,3,… instead of +50 jumps

    /// The output-token use case. The CLI reports the thinking estimate as
    /// coarse cumulative jumps (+50, +50, …). Fed through the pacer, the
    /// displayed counter must climb **continuously** — visiting the integers in
    /// between — never stepping a whole +50 in one frame.
    func testCounterClimbsContinuouslyBetweenCoarseJumps() {
        var pacer = StreamPacer(params: .counter)
        var seen = Set<Int>()
        var maxStep = 0
        var prev = 0
        var target = 0.0

        // Five +50 cumulative jumps, each 0.5s (30 frames) apart.
        for jump in 0..<5 {
            target = Double((jump + 1) * 50)
            pacer.setTarget(target)
            for _ in 0..<30 {
                let shown = pacer.advance(dt: frame)
                maxStep = max(maxStep, shown - prev)
                prev = shown
                seen.insert(shown)
            }
        }
        // Drain to the final target.
        var guardFrames = 0
        while pacer.hasBacklog, guardFrames < 600 {
            let shown = pacer.advance(dt: frame)
            maxStep = max(maxStep, shown - prev)
            prev = shown
            seen.insert(shown)
            guardFrames += 1
        }

        XCTAssertEqual(pacer.displayed, 250, "must reach the final cumulative total")
        XCTAssertLessThan(
            maxStep, 50,
            "a whole +50 jump appeared in one frame (max step \(maxStep)) — not a continuous count")
        XCTAssertGreaterThan(
            seen.count, 100,
            "the counter should pass through many intermediate values, not snap (saw \(seen.count))")
    }

    // MARK: - Velocity is smooth too (the second-order upgrade)

    /// The headline of the second-order servo: not just smooth *position*, but a
    /// smooth *typing rate*. Under the real Haiku cadence, the displayed velocity
    /// must change gently from frame to frame — no per-burst speed jump — and be
    /// dramatically steadier than the first-order law it replaces, which jumped
    /// `chunk/τ` (tens of units/s) the instant each burst landed.
    ///
    /// We replay the same trace through the production pacer and a
    /// `FirstOrderReference` (the shipped-before law) and compare the frame-to-
    /// frame velocity change in the mid-stream window (warm-up and tail excluded).
    func testVelocityIsSmoothUnderRealCadence() {
        var ref = FirstOrderReference()
        var prevNew = 0.0
        var prevOld = 0.0
        var newJumps: [Double] = []
        var oldJumps: [Double] = []
        var newVels: [Double] = []

        replayHaiku { pacer, f, owedMore in
            ref.setTarget(pacer.target)
            ref.advance(dt: 1.0 / 60.0)
            // Mid-stream only: past the EWMA warm-up, before the drain tail.
            guard f > 40, owedMore else {
                prevNew = pacer.displayVelocity
                prevOld = ref.velocity
                return
            }
            newJumps.append(abs(pacer.displayVelocity - prevNew))
            oldJumps.append(abs(ref.velocity - prevOld))
            newVels.append(pacer.displayVelocity)
            prevNew = pacer.displayVelocity
            prevOld = ref.velocity
        }

        // The jitter is the *sparse* spike when a burst lands (~1 frame in 14),
        // so the worst-case (max) and tail (p95) per-frame velocity change are the
        // metrics that see it — a low percentile would step right over the spikes.
        let newMax = newJumps.max() ?? 0
        let oldMax = oldJumps.max() ?? 0
        let newP95 = percentile(newJumps, 0.95)
        let oldP95 = percentile(oldJumps, 0.95)
        let newMean = newVels.reduce(0, +) / Double(newVels.count)
        let minNewVel = newVels.min() ?? 0

        // The baseline really is jittery — otherwise the comparison is hollow.
        // (First-order law: ~98 u/s worst jump, ~45 at p95.)
        XCTAssertGreaterThan(
            oldMax, 50,
            "first-order baseline worst velocity jump was only \(oldMax) — not jittery, "
                + "comparison meaningless")

        // The fix: the typing rate changes smoothly — the worst single-frame
        // velocity change is small in absolute terms (measured ≈ 9 u/s)…
        XCTAssertLessThan(
            newMax, 20,
            "second-order worst velocity jump \(newMax) u/s — the typing rate still pulses")
        XCTAssertLessThan(
            newP95, 8,
            "second-order p95 velocity jump \(newP95) u/s — the typing rate still pulses")
        // …and a small fraction of what the first-order law produced.
        XCTAssertLessThan(
            newMax, oldMax * 0.35,
            "second-order worst jump \(newMax) vs first-order \(oldMax) — not a clear improvement")

        // Smoothness must not come from crawling: the head still moves at roughly
        // the ~77 char/s arrival rate, and never freezes mid-stream.
        XCTAssertGreaterThan(minNewVel, 0, "velocity hit 0 mid-stream — the reveal froze")
        XCTAssertEqual(
            newMean, 77, accuracy: 35,
            "mean display velocity \(newMean) strayed far from the ~77 char/s arrival rate")
    }

    /// A single burst, then silence: the velocity must ramp up from rest, crest
    /// once, and ease back to 0 — a single smooth hump with **no ringing**
    /// (the critically-damped, no-overshoot signature). An under-damped servo
    /// would overshoot and oscillate: the velocity would dip and rise again.
    func testSingleStepVelocityIsAUnimodalHumpNoRinging() {
        var pacer = StreamPacer(params: .text)
        pacer.setTarget(100)

        var vels: [Double] = []
        var emittedSeq: [Double] = []
        for _ in 0..<240 {
            pacer.advance(dt: frame)
            vels.append(pacer.displayVelocity)
            emittedSeq.append(pacer.displayedExact)
            if pacer.isCaughtUp { break }
        }

        // Never negative (would un-reveal), and the position is monotone and
        // never passes target (causal + no overshoot).
        XCTAssertTrue(vels.allSatisfy { $0 >= 0 }, "velocity went negative")
        XCTAssertTrue(
            zip(emittedSeq, emittedSeq.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 },
            "displayed count moved backward — overshoot/oscillation")
        XCTAssertTrue(emittedSeq.allSatisfy { $0 <= 100 + 1e-9 }, "passed the received boundary")
        XCTAssertTrue(pacer.isCaughtUp, "a fully-received burst must converge")

        // Unimodal: rises from rest to a single crest, then only falls. Count the
        // crest, then assert the velocity never climbs again afterward (beyond a
        // small deadband that absorbs sub-step/numeric noise) — i.e. no ring.
        let peakIdx = vels.firstIndex(of: vels.max() ?? 0) ?? 0
        XCTAssertGreaterThan(peakIdx, 0, "velocity should ramp up from rest, not start at its peak")
        let deadband = 1.0
        var roseAfterPeak = false
        for i in (peakIdx + 1)..<vels.count where vels[i] > vels[i - 1] + deadband {
            roseAfterPeak = true
        }
        XCTAssertFalse(roseAfterPeak, "velocity rose again after its crest — under-damped ringing")
    }

    /// A steady bursty stream (12 units every 5 frames ≈ 144 u/s, the cadence
    /// `testSteadyBurstyStreamDoesNotStutter` uses for *position*) must, once
    /// warmed up, hold a near-constant *velocity*: the per-frame velocity change
    /// is a tiny fraction of the mean (measured ≈ 1.2 u/s against a ~144 u/s
    /// mean). This is the deterministic companion to the real-cadence proof —
    /// the first-order law would step `12/τ ≈ 48 u/s` each time a burst lands.
    func testSteadyStreamHoldsNearConstantVelocity() {
        var pacer = StreamPacer(params: .text)
        var target = 0.0
        var prev = 0.0
        var maxJump = 0.0
        var vels: [Double] = []
        for f in 0..<240 {
            if f % 5 == 0 {
                target += 12
                pacer.setTarget(target)
            }
            pacer.advance(dt: frame)
            if f >= 90 {  // steady state, past the EWMA warm-up
                maxJump = max(maxJump, abs(pacer.displayVelocity - prev))
                vels.append(pacer.displayVelocity)
            }
            prev = pacer.displayVelocity
        }
        let mean = vels.reduce(0, +) / Double(vels.count)
        XCTAssertEqual(mean, 144, accuracy: 20, "velocity should track the 144 u/s arrival rate")
        XCTAssertLessThan(
            maxJump, 5,
            "velocity changed by \(maxJump) u/s between frames at steady state — not constant")
    }

    // MARK: - Catch-up under a high arrival rate (the gap must not diverge)

    /// "Catch up" defined precisely: the lag (`backlog`) must **not grow without
    /// bound** as the stream runs on. With no `maxRate` ceiling, the steady-state
    /// velocity equals the arrival rate (feed-forward) at *any* rate, so the
    /// backlog settles to the playout cushion and stays there. We feed **900 u/s**
    /// — deliberately above the old `maxRate` of 700, where a capped pacer would
    /// be stuck at 700 < 900 and the backlog would climb (900−700) every second
    /// forever — and assert the gap plateaus instead: the late window is no larger
    /// than the early one. (Measured: it settles at ~440 ≈ the 450 cushion.)
    func testHighArrivalRateDoesNotLetTheGapDiverge() {
        var pacer = StreamPacer(params: .text)
        var target = 0.0
        let perFrame = 15.0  // 900 units/s — above the *old* 700/s cap
        var backlog: [Double] = []
        for _ in 0..<1200 {  // 20s of sustained high-rate streaming
            target += perFrame
            pacer.setTarget(target)
            pacer.advance(dt: frame)
            backlog.append(pacer.backlog)
        }
        // Early steady window (after the velocity has ramped up) vs a far later
        // one. The defining property: the late gap is not bigger than the early
        // gap — it plateaued instead of diverging.
        let early = backlog[150..<300].max() ?? 0  // ~2.5–5s
        let late = backlog[1050..<1200].max() ?? 0  // ~17.5–20s
        XCTAssertLessThanOrEqual(
            late, early + 5,
            "backlog grew from \(early) to \(late) over 20s — the gap diverges, never caught up")
        // It settled near the playout cushion (rate·latency = 900·0.5 = 450), i.e.
        // it is genuinely tracking a rate the old cap could not have kept up with.
        XCTAssertLessThan(late, 550, "steady backlog \(late) far exceeds the ~450 cushion — not tracking")
        XCTAssertGreaterThan(late, 0, "must keep a cushion, not collapse onto the boundary")
    }

    /// Why the `maxRate` cap was dropped: it throttled a large finalize to a
    /// crawl. A 12k-char message sealed all at once drains in a handful of frames
    /// because the drain speed is set by the servo's natural frequency, not a
    /// fixed rate — whereas the old 700 u/s cap would have forced 12000/700 ≈ 17s
    /// (~1029 frames) of typing after the message was already complete.
    func testLargeFinalizeDrainsQuicklyWithNoRateCap() {
        var pacer = StreamPacer(params: .text)
        pacer.setTarget(12000)
        pacer.seal()
        var frames = 0
        while pacer.hasBacklog, frames < 600 {
            pacer.advance(dt: frame)
            frames += 1
        }
        XCTAssertTrue(pacer.isCaughtUp, "a sealed finalize must converge")
        XCTAssertLessThan(
            frames, 90,
            "a 12k-char finalize took \(frames) frames (\(Double(frames) / 60)s) — a rate cap is throttling it")
    }

    /// `percentile(xs, p)` — the p-quantile by nearest-rank, for the robust
    /// velocity-jump metric (a single double-chunk arrival shouldn't dominate).
    private func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let rank = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// The first-order pacing law the second-order servo replaces — display velocity
/// recomputed *every frame* as `r̂ + (backlog − cushion)/τ`, with **no velocity
/// state**. Because both terms step-jump the instant a burst lands, the velocity
/// is discontinuous (the rate jitter the user felt). Kept here as a baseline so
/// `testVelocityIsSmoothUnderRealCadence` can assert the second-order servo's
/// velocity is dramatically steadier than what shipped before.
private struct FirstOrderReference {
    var target = 0.0
    var emitted = 0.0
    var rate = 0.0
    var lastTarget = 0.0
    var velocity = 0.0
    let tauRate = 0.35
    let tauCatchUp = 0.25
    let latency = 0.3
    let maxRate = 700.0

    mutating func setTarget(_ total: Double) { if total > target { target = total } }

    mutating func advance(dt: Double) {
        let grew = max(0, target - lastTarget)
        lastTarget = target
        let sample = grew / dt
        let alpha = 1 - exp(-dt / tauRate)
        rate += alpha * (sample - rate)
        let backlog = max(0, target - emitted)
        let cushion = rate * latency
        velocity = min(max(rate + (backlog - cushion) / tauCatchUp, 0), maxRate)
        emitted = min(emitted + velocity * dt, target)
    }
}

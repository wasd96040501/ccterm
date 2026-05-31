import XCTest

@testable import ccterm

/// Pure tests for `StreamPacer` — the EWMA-rate-estimating, first-order-servo
/// pacer that decouples a bursty received total from a smooth displayed total.
/// No UI, no ticker; the pacer is stepped by hand at a fixed 60fps `dt`.
///
/// These prove the four properties the design promises: it never overshoots the
/// received boundary, it does **not** stutter between bursts (the bug), it
/// catches up when it falls behind, and it always converges once the stream
/// ends.
final class StreamPacerTests: XCTestCase {

    private let frame = 1.0 / 60.0

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

    /// Replays the **real** SSE cadence captured from a `claude-haiku` long-story
    /// turn (`PartialMessagesSmoke`): ~17-char chunks arriving a median 228ms
    /// apart (p90 281ms, with 674/416/439ms outliers). With the cushion too small
    /// to bridge a 228ms gap, the display catches the boundary between chunks and
    /// the buffer runs dry — the "1/3-line stutter". We replay the trace frame by
    /// frame and count dry frames (buffer empty while more deltas are still owed).
    func testRealHaikuCadenceKeepsTheBufferFull() {
        // (chars, gapMsFromPrevDelta) — verbatim from the smoke run.
        let trace: [(len: Int, gap: Double)] = [
            (17, 0), (20, 267), (15, 206), (17, 262), (18, 213), (18, 211), (15, 210),
            (11, 237), (13, 234), (22, 238), (14, 212), (22, 237), (22, 235), (12, 211),
            (18, 217), (11, 228), (16, 211), (10, 235), (21, 238), (15, 262), (16, 210),
            (13, 315), (13, 210), (9, 242), (22, 674), (14, 4), (16, 1), (18, 256),
            (17, 301), (15, 158), (23, 149), (21, 215), (14, 416), (12, 57), (23, 439),
            (20, 112), (21, 298), (22, 156), (18, 232), (17, 242), (14, 321), (24, 226),
        ]
        // Absolute arrival time (ms) of each delta.
        var arrival: [Double] = []
        var clock = 0.0
        for d in trace {
            clock += d.gap
            arrival.append(clock)
        }
        let lastArrival = arrival.last ?? 0

        var pacer = StreamPacer(params: .text)
        var target = 0.0
        var next = 0
        var simMs = 0.0
        let frameMs = 1000.0 / 60.0
        var dryFrames = 0

        var f = 0
        while simMs <= lastArrival + 2000 {  // +2s tail to drain
            simMs += frameMs
            while next < trace.count, arrival[next] <= simMs {
                target += Double(trace[next].len)
                pacer.setTarget(target)
                next += 1
            }
            pacer.advance(dt: frameMs / 1000)
            // A dry buffer while deltas are still owed is a mid-stream stall.
            if f > 30, next < trace.count, pacer.backlog < 0.5 { dryFrames += 1 }
            f += 1
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
    /// frames (capped by `maxRate`), not pop in at once — and then converge.
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
}

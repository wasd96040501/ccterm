import Foundation
import QuartzCore

/// Drives a per-frame callback for the streaming typewriter reveal.
///
/// Abstracted behind a protocol so production uses a real main-loop frame
/// timer while unit tests inject a manual ticker they step deterministically.
/// The display-driven path cannot run as a CI merge gate (see
/// `cctermTests/CLAUDE.md` — display-link-backed tests are skipped on CI), so
/// the reveal logic is exercised by stepping a `ManualFrameTicker`, not by
/// waiting on real frames.
@MainActor
protocol FrameTicker: AnyObject {
    /// Begin delivering ticks. `onTick(dt)` fires once per frame with the
    /// elapsed seconds since the previous tick. Calling `start` while already
    /// running replaces the callback and resets the clock.
    func start(_ onTick: @escaping (_ dt: Double) -> Void)
    /// Stop delivering ticks. Idempotent.
    func stop()
}

/// Production `FrameTicker`: a `Timer` on the main run loop in `.common`
/// modes, so the reveal keeps advancing through scroll / resize tracking.
///
/// A timer rather than `CADisplayLink`: discrete glyph reveals don't need
/// vsync alignment, and the weak-capturing block self-invalidates when the
/// owner deallocates — no retain cycle (the run loop owns the scheduled timer;
/// the block only weakly holds the ticker) and no fragile cross-thread
/// `invalidate` in `deinit`.
@MainActor
final class TimerFrameTicker: FrameTicker {

    private var timer: Timer?
    private var lastTime: CFTimeInterval = 0
    private let interval: TimeInterval
    /// Held on the ticker (not captured by the `@Sendable` timer block) so the
    /// block only weakly references `self` — no non-Sendable capture.
    private var onTick: ((Double) -> Void)?

    init(fps: Double = 60) {
        self.interval = 1.0 / fps
    }

    func start(_ onTick: @escaping (Double) -> Void) {
        stop()
        self.onTick = onTick
        lastTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            // Scheduled on the main run loop, so the fire is always on the
            // main thread — assert the isolation rather than hop a frame late.
            MainActor.assumeIsolated {
                guard let self else {
                    t.invalidate()
                    return
                }
                let now = CACurrentMediaTime()
                let dt = now - self.lastTime
                self.lastTime = now
                self.onTick?(dt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onTick = nil
    }

    /// `nonisolated` to dodge the macOS 26 `@MainActor`-deinit abort (same
    /// rationale as the runtime's `nonisolated deinit`). A live timer is left
    /// to its weak-self block, which invalidates it on the next fire when the
    /// ticker is gone — a ≤ one-frame self-healing leak, never a cycle.
    nonisolated deinit {}
}

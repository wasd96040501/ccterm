import AppKit
import QuartzCore
import XCTest

@testable import ccterm

/// Per-frame animation sampler. Generalizes the `PresentationSampler`
/// that lived inside `TranscriptScrollLivePresentationSnapshotTests`:
/// instead of only the clip-view origin, it samples **any** view's
/// `layer.presentation()` frame + opacity on every `CADisplayLink` tick,
/// so a test can assert on the *animation curve* — what the render server
/// actually composited frame by frame — not just the resting state.
///
/// This is the layer that answers "during the crossfade, did opacity rise
/// monotonically / did the position jump / where did it land." It samples
/// `presentation()` (the in-flight render-tree value), not the model
/// layer, so it sees the interpolated frames a user would have seen.
///
/// ## Driving off `NSScreen.main`
///
/// The display link is created on `NSScreen.main`, not `view.displayLink`.
/// The view's own link only fires when the view is visible on a screen,
/// but the harness window sits at `(-30_000, -30_000)` with
/// `alphaValue = 0.01`. The screen link fires unconditionally at the
/// refresh rate — exactly the "sample every refresh tick" behavior we
/// want. (The render server still composites this window; the sibling
/// flush probe in `TranscriptScrollFirstFrameSnapshotTests` established
/// that `presentation()` returns post-flush values here.)
@MainActor
enum AnimationProbe {

    /// One per-frame sample of a tracked view's presentation layer.
    struct Sample {
        let frameIndex: Int
        let elapsedMillis: Double
        /// `presentation().frame` in the layer's own coordinate space, or
        /// nil if the render server hasn't composited the layer yet.
        let presentationFrame: CGRect?
        /// `presentation().opacity`, or nil if not yet composited.
        let opacity: Float?
    }

    /// A captured animation timeline with assertion helpers.
    struct Timeline {
        let samples: [Sample]

        /// Samples that actually had a composited presentation layer.
        var composited: [Sample] { samples.filter { $0.presentationFrame != nil } }

        /// Opacity rose (or fell) monotonically across composited frames,
        /// within `tolerance` slack for render jitter, ending at `to`.
        func assertOpacity(
            from start: Float, to end: Float, monotonic: Bool = true,
            tolerance: Float = 0.02,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            let ops = composited.compactMap { $0.opacity }
            guard let first = ops.first, let last = ops.last else {
                XCTFail("assertOpacity: no composited opacity samples\n\(report())", file: file, line: line)
                return
            }
            XCTAssertEqual(
                first, start, accuracy: max(tolerance, 0.15),
                "opacity should start ≈ \(start), got \(first)\n\(report())", file: file, line: line)
            XCTAssertEqual(
                last, end, accuracy: tolerance,
                "opacity should end ≈ \(end), got \(last)\n\(report())", file: file, line: line)
            if monotonic {
                let rising = end >= start
                for (prev, next) in zip(ops, ops.dropFirst()) {
                    let ok = rising ? (next >= prev - tolerance) : (next <= prev + tolerance)
                    XCTAssertTrue(
                        ok,
                        "opacity not monotonic (\(rising ? "rising" : "falling")): "
                            + "\(prev) → \(next)\n\(report())", file: file, line: line)
                }
            }
        }

        /// No single-frame jump of the tracked attribute exceeds `maxStep`
        /// points between consecutive composited frames — catches a
        /// teleport mid-animation (e.g. a position that snaps instead of
        /// tweening).
        enum Attribute { case originX, originY, position }
        func assertNoJump(
            _ attr: Attribute, maxStep: CGFloat,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            let frames = composited.compactMap { $0.presentationFrame }
            for (prev, next) in zip(frames, frames.dropFirst()) {
                let step: CGFloat
                switch attr {
                case .originX: step = abs(next.minX - prev.minX)
                case .originY: step = abs(next.minY - prev.minY)
                case .position:
                    step = hypot(next.midX - prev.midX, next.midY - prev.midY)
                }
                XCTAssertLessThanOrEqual(
                    step, maxStep,
                    "\(attr) jumped \(String(format: "%.1f", step))pt > \(maxStep)pt "
                        + "between frames\n\(report())", file: file, line: line)
            }
        }

        /// The final composited opacity equals `value` within `accuracy`.
        func assertFinalOpacity(
            _ value: Float, accuracy: Float = 0.02,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            guard let last = composited.compactMap({ $0.opacity }).last else {
                XCTFail("assertFinalOpacity: no composited samples\n\(report())", file: file, line: line)
                return
            }
            XCTAssertEqual(last, value, accuracy: accuracy, "\n\(report())", file: file, line: line)
        }

        /// Human-readable per-frame dump, for `XCTAttachment` or failure
        /// messages.
        func report() -> String {
            var lines = ["animation timeline (\(samples.count) frames, \(composited.count) composited)"]
            for s in samples {
                let fr =
                    s.presentationFrame.map {
                        String(format: "(%.1f,%.1f %.1f×%.1f)", $0.minX, $0.minY, $0.width, $0.height)
                    } ?? "nil"
                let op = s.opacity.map { String(format: "%.3f", $0) } ?? "nil"
                lines.append(
                    String(
                        format: "  f%3d @%7.1fms  frame=%@  opacity=%@",
                        s.frameIndex, s.elapsedMillis, fr, op))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Run `trigger` (the action that starts the animation) and sample
    /// `view`'s presentation layer for up to `frames` display-link ticks /
    /// `timeout` seconds, whichever first. Returns the captured `Timeline`.
    ///
    /// `trigger` runs *after* the display link is armed, so the first
    /// composited frame of the animation lands in the timeline.
    static func record(
        _ view: NSView,
        frames: Int = 30,
        timeout: TimeInterval = 0.6,
        during trigger: () -> Void
    ) -> Timeline {
        let sampler = Sampler(view: view)
        guard sampler.start() else {
            XCTFail(
                "AnimationProbe: no CADisplayLink available (headless / no display). "
                    + "Render-server timing cannot be probed in this environment.")
            return Timeline(samples: [])
        }
        defer { sampler.stop() }

        trigger()

        let deadline = Date().addingTimeInterval(timeout)
        while sampler.count < frames, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return Timeline(samples: sampler.snapshot())
    }

    // MARK: - Sampler

    private final class Sampler {
        private let view: NSView
        private var displayLink: CADisplayLink?
        private var samples: [Sample] = []
        private var startTime: CFTimeInterval = 0
        private var frameCounter = 0

        init(view: NSView) { self.view = view }

        func start() -> Bool {
            guard let screen = NSScreen.main else { return false }
            let dl = screen.displayLink(target: self, selector: #selector(tick(_:)))
            displayLink = dl
            dl.add(to: .main, forMode: .common)
            startTime = CACurrentMediaTime()
            return true
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        var count: Int { samples.count }
        func snapshot() -> [Sample] { samples }

        @objc private func tick(_ link: CADisplayLink) {
            let elapsedMs = (CACurrentMediaTime() - startTime) * 1000
            let presentation = view.layer?.presentation()
            samples.append(
                Sample(
                    frameIndex: frameCounter,
                    elapsedMillis: elapsedMs,
                    presentationFrame: presentation?.frame,
                    opacity: presentation?.opacity))
            frameCounter += 1
        }
    }
}

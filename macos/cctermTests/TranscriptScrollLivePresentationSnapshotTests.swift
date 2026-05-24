import AppKit
import QuartzCore
import XCTest

@testable import ccterm

/// Sibling to `TranscriptScrollFirstFrameSnapshotTests`. That file
/// proved the **model** layer lands at tail in the very first source
/// phase, and that `CATransaction.flush()` propagates that write to the
/// **presentation** tree synchronously (see test 3 of that file). What
/// it cannot see is whether the **render server** actually composites a
/// frame at tail first, or whether it sneaks a prior "at top" frame in
/// because the layer was already in the layer tree before our write.
///
/// This file installs a `CADisplayLink` against the offscreen test
/// window and records `(model.bounds.origin.y,
/// presentation().bounds.origin.y)` on every composited frame for up to
/// ~30 frames. The first sample where `presentation` is non-nil is the
/// first frame the render server actually drew — that frame's origin is
/// what the user would have seen.
///
/// Caveats this scaffold inherits from the offscreen window setup:
///
/// - The window is at `(-30_000, -30_000)` with `alphaValue = 0.01` so
///   we don't steal focus. AppKit still treats it as "in a screen" for
///   layout, and the render server still composites it (verified by
///   the flush test reporting a non-nil presentation after a flush) —
///   but if a future SDK change drops compositing for nearly-invisible
///   windows, the display link will fire and presentation will stay
///   nil. The test handles that case by failing with a clear message
///   so it cannot silently degrade into a no-op.
/// - The test file is `*SnapshotTests`, so it's opt-in and CI-skipped
///   (same as `TranscriptScrollFirstFrameSnapshotTests`).
///
/// Filename matches the class so the runner's filename-keyed skip
/// works.
@MainActor
final class TranscriptScrollLivePresentationSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture (mirrors TranscriptScrollFirstFrameSnapshotTests)

    private static let blockCount = 60
    private static let windowSize = CGSize(width: 720, height: 800)

    private func makeBlocks() -> [Block] {
        (0..<Self.blockCount).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "line \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }

    private func prepopulatedController() -> Transcript2Controller {
        let c = Transcript2Controller()
        c.apply(.append(makeBlocks()))
        XCTAssertEqual(c.blockIds.count, Self.blockCount, "fixture: append should land all blocks")
        return c
    }

    // MARK: - Test

    /// Asserts: the **first composited frame** after a source-phase
    /// `attachSession`-equivalent sequence has `presentation.origin.y`
    /// at the tail, not at the `-contentInsets.top` clamp.
    ///
    /// Guards the **content layer** specifically. Scrollbar /
    /// scroller-chrome regressions live in
    /// `TranscriptScrollFirstFrameSnapshotTests.testScrollerKnobLandsAtTailAfterScrollToTail`
    /// — sample both dimensions when a visual glitch is reported,
    /// since the content layer landing at tail does not by itself
    /// rule out a desynced scroller.
    func testFirstCompositedFramePresentationLandsAtTail() throws {
        let controller = prepopulatedController()
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        let (window, container) = makeOffscreenWindow(content: scroll)
        defer { dismantleWindow(window) }

        // Display link must be ready before the layout / scroll cascade
        // so the very first frame the render server composites lands in
        // `samples`. Created on the scroll view (its screen drives the
        // refresh rate); falls back to the main screen if the view's
        // window isn't bound to one yet.
        let sampler = PresentationSampler(scroll: scroll)
        guard sampler.start() else {
            XCTFail(
                "could not obtain a CADisplayLink for the scroll view nor for the "
                    + "main screen — render-server probe is impossible in this "
                    + "environment (likely headless / no display attached).")
            return
        }
        defer { sampler.stop() }

        // Production attach sequence (mirrors
        // ChatSessionViewController.attachSession + #199's
        // scrollToTail anchor — same as the model-only test).
        container.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        let modelAfterLayout = scroll.contentView.bounds.origin.y
        controller.scrollToTail()
        let modelAfterScroll = scroll.contentView.bounds.origin.y

        // Pump the runloop until we've captured at least
        // `targetSamples` display-link frames, or `deadline` passes.
        let targetSamples = 30
        let deadline = Date().addingTimeInterval(0.5)
        while sampler.sampleCount < targetSamples, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }

        let samples = sampler.snapshot()
        let m = measure(scroll: scroll)
        let visibleBottomInClip = m.clipHeight - m.contentInsets.bottom
        let expectedTailOrigin = m.documentHeight - visibleBottomInClip
        let topClamp = -m.contentInsets.top

        let report = renderReport(
            samples: samples,
            modelAfterLayout: modelAfterLayout,
            modelAfterScroll: modelAfterScroll,
            documentHeight: m.documentHeight,
            clipHeight: m.clipHeight,
            contentInsets: m.contentInsets,
            expectedTailOrigin: expectedTailOrigin,
            topClamp: topClamp)
        attachString(report, name: "display-link-timeline")

        XCTAssertGreaterThan(
            samples.count, 0,
            "display link never fired — runloop drain too short, or the view's "
                + "screen has no display link. Cannot probe render-server timing.")

        guard let firstComposited = samples.first(where: { $0.presentationOrigin != nil }) else {
            XCTFail(
                "captured \(samples.count) display-link callbacks but every "
                    + "presentation() read returned nil — the render server is not "
                    + "compositing this layer at all (offscreen window may be "
                    + "skipped). Without compositing we cannot probe what the user "
                    + "would see; try a different scaffold (visible window or "
                    + "screen-capture probe).")
            return
        }

        let firstY = firstComposited.presentationOrigin!
        let pinnedAtTop = abs(firstY - topClamp) < 1
        XCTAssertFalse(
            pinnedAtTop,
            "FIRST COMPOSITED FRAME at top, not tail. "
                + "presentation.origin.y on frame \(firstComposited.frameIndex) "
                + "(\(String(format: "%.1f", firstComposited.elapsedMillis))ms after attach) "
                + "= \(firstY), which is ≈ -contentInsets.top = \(topClamp). "
                + "Expected ≈ \(expectedTailOrigin) (tail). "
                + "Subsequent frames: "
                + samples.prefix(8).map {
                    "f\($0.frameIndex)=\($0.presentationOrigin.map { String(format: "%.1f", $0) } ?? "nil")"
                }.joined(separator: " "))

        XCTAssertEqual(
            firstY, expectedTailOrigin, accuracy: 2.0,
            "first composited presentation.origin.y should match tail within 2pt; "
                + "got \(firstY), expected ≈ \(expectedTailOrigin). Full timeline "
                + "in the attached display-link-timeline report.")
    }

    // MARK: - Helpers

    private struct Measurement {
        let documentHeight: CGFloat
        let clipHeight: CGFloat
        let contentInsets: NSEdgeInsets
    }

    private func measure(scroll: NSScrollView) -> Measurement {
        let table = scroll.documentView as! NSTableView
        return Measurement(
            documentHeight: table.frame.height,
            clipHeight: scroll.contentView.bounds.height,
            contentInsets: scroll.contentInsets)
    }

    private func renderReport(
        samples: [PresentationSampler.Sample],
        modelAfterLayout: CGFloat,
        modelAfterScroll: CGFloat,
        documentHeight: CGFloat,
        clipHeight: CGFloat,
        contentInsets: NSEdgeInsets,
        expectedTailOrigin: CGFloat,
        topClamp: CGFloat
    ) -> String {
        var lines: [String] = []
        lines.append("display-link presentation timeline")
        lines.append(String(repeating: "─", count: 60))
        lines.append("documentHeight = \(documentHeight)")
        lines.append("clipHeight     = \(clipHeight)")
        lines.append("contentInsets  = top=\(contentInsets.top) bottom=\(contentInsets.bottom)")
        lines.append("expected tail origin = \(expectedTailOrigin)")
        lines.append("top-clamp            = \(topClamp)")
        lines.append("")
        lines.append("source-phase model samples (no runloop drain between):")
        lines.append("  after container.layoutSubtreeIfNeeded() = \(modelAfterLayout)")
        lines.append("  after controller.scrollToTail()         = \(modelAfterScroll)")
        lines.append("")
        lines.append("display-link callbacks (\(samples.count) total):")
        if samples.isEmpty {
            lines.append("  (none — display link never fired during the drain window)")
        } else {
            for s in samples {
                let mo = String(format: "%.2f", s.modelOrigin)
                let po = s.presentationOrigin.map { String(format: "%.2f", $0) } ?? "nil"
                lines.append(
                    "  frame \(String(format: "%3d", s.frameIndex)) "
                        + "@ \(String(format: "%6.1f", s.elapsedMillis))ms  "
                        + "model=\(mo)  presentation=\(po)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func attachString(_ s: String, name: String) {
        let a = XCTAttachment(string: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func makeOffscreenWindow(content: NSView) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: Self.windowSize),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        return (window, container)
    }

    private func dismantleWindow(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }
}

/// Records `(model, presentation)` clip-view origin samples on each
/// `CADisplayLink` callback. Lives in this file because nothing else
/// needs render-server timing probes; if a sibling test wants the same
/// shape, lift this into `Helpers/`.
@MainActor
private final class PresentationSampler {
    struct Sample {
        let frameIndex: Int
        let elapsedMillis: Double
        let modelOrigin: CGFloat
        let presentationOrigin: CGFloat?
    }

    private let scroll: NSScrollView
    private var displayLink: CADisplayLink?
    private(set) var samples: [Sample] = []
    private var startTime: CFTimeInterval = 0
    private var frameCounter: Int = 0

    init(scroll: NSScrollView) {
        self.scroll = scroll
    }

    /// Returns false if no display link can be obtained (no main
    /// screen — headless / no display attached).
    ///
    /// We deliberately drive off `NSScreen.main` rather than
    /// `NSView.displayLink`: the view's own link only fires when the
    /// view is visible on a screen, and our test window sits at
    /// (-30_000, -30_000) with `alphaValue = 0.01`. The screen-level
    /// link fires unconditionally at the screen's refresh rate, which
    /// is what we want — we're sampling state every refresh tick,
    /// independent of whether the render server picked our specific
    /// window for compositing.
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

    var sampleCount: Int { samples.count }

    func snapshot() -> [Sample] { samples }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsedMs = (CACurrentMediaTime() - startTime) * 1000
        let clip = scroll.contentView
        let model = clip.bounds.origin.y
        let presented = clip.layer?.presentation()?.bounds.origin.y
        samples.append(
            Sample(
                frameIndex: frameCounter,
                elapsedMillis: elapsedMs,
                modelOrigin: model,
                presentationOrigin: presented))
        frameCounter += 1
    }
}

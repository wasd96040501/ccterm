import AppKit
import QuartzCore

/// Reads what CoreAnimation presents, frame by frame (SPEC §13, motion).
///
/// Two ways, both real CoreAnimation evaluation:
/// - **Scrubbing**: freezes an ancestor layer's time (`speed = 0`) and moves its
///   `timeOffset`, so `presentation()` is evaluated at exactly the `t` asked for.
///   Deterministic; this is what the formula checks use.
/// - **Display-link timeline**: samples `presentation()` on every refresh of
///   `NSScreen.main`, the frames the render server actually showed. macOS 14+.
@MainActor
public final class PresentationSampler {

    private let root: CALayer

    /// The root's local time at the freeze. Animations added underneath while
    /// frozen begin here.
    private let frozenAt: CFTimeInterval

    /// Freezes time on `root`, from the next animation added underneath it.
    public init(freezing root: CALayer) {
        self.root = root
        frozenAt = root.convertTime(CACurrentMediaTime(), from: nil)
        root.speed = 0
        root.timeOffset = frozenAt
        CATransaction.flush()
    }

    /// Moves the frozen time to `seconds` after the freeze, and flushes.
    public func scrub(to seconds: TimeInterval) {
        root.timeOffset = frozenAt + seconds
        CATransaction.flush()
    }

    /// `view`'s presented frame in `ancestor`'s coordinates, from its layer's
    /// `presentation()` and every presented ancestor between them. `ancestor`
    /// should be flipped, as the list is, so the frame reads top-down.
    public func presentedFrame(of view: NSView, in ancestor: NSView) -> CGRect {
        guard let layer = view.layer, let target = ancestor.layer else {
            preconditionFailure("presentedFrame needs layer-backed views")
        }
        let presented = layer.presentation() ?? layer
        let into = target.presentation() ?? target
        return into.convert(presented.bounds, from: presented)
    }

    /// `view`'s presented opacity.
    public func presentedOpacity(of view: NSView) -> Float {
        guard let layer = view.layer else { preconditionFailure("presentedOpacity needs a layer-backed view") }
        return (layer.presentation() ?? layer).opacity
    }

    /// Releases the freeze: time carries on from where it was scrubbed to.
    public func thaw() {
        let paused = root.timeOffset
        root.speed = 1
        root.timeOffset = 0
        root.beginTime = 0
        root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
        CATransaction.flush()
    }

    /// One display-link sample: the presented frames, in `ancestor`'s
    /// coordinates, of the tracked views that are showing (in the window, not
    /// hidden).
    public struct Frame {
        public let elapsed: TimeInterval
        public let frames: [ObjectIdentifier: CGRect]
    }

    /// Samples `views` on every refresh for `duration`, without freezing time.
    @available(macOS 14, *)
    public static func record(_ views: [NSView], in ancestor: NSView, for duration: TimeInterval) async -> [Frame] {
        await withCheckedContinuation { (done: CheckedContinuation<[Frame], Never>) in
            let recorder = DisplayLinkRecorder(views: views, ancestor: ancestor, duration: duration) { frames in
                done.resume(returning: frames)
            }
            recorder.start()
        }
    }
}

/// The display link's target: an `NSObject`, which `NSScreen.displayLink`
/// requires. It keeps itself alive through the link until `duration` passes.
@available(macOS 14, *)
@MainActor
private final class DisplayLinkRecorder: NSObject {

    private let views: [NSView]
    private let ancestor: NSView
    private let duration: TimeInterval
    private let finish: ([PresentationSampler.Frame]) -> Void
    private var frames: [PresentationSampler.Frame] = []
    private var link: CADisplayLink?
    private var start0: CFTimeInterval = 0

    init(
        views: [NSView], ancestor: NSView, duration: TimeInterval,
        finish: @escaping ([PresentationSampler.Frame]) -> Void
    ) {
        self.views = views
        self.ancestor = ancestor
        self.duration = duration
        self.finish = finish
    }

    func start() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            preconditionFailure("no screen to drive a display link")
        }
        start0 = CACurrentMediaTime()
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - start0
        var sample: [ObjectIdentifier: CGRect] = [:]
        let into = ancestor.layer.map { $0.presentation() ?? $0 }
        for view in views {
            // A view out of the window or hidden shows nothing, wherever its
            // layer is.
            guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
            guard let layer = view.layer, let into else { continue }
            let presented = layer.presentation() ?? layer
            sample[ObjectIdentifier(view)] = into.convert(presented.bounds, from: presented)
        }
        frames.append(PresentationSampler.Frame(elapsed: elapsed, frames: sample))
        if elapsed >= duration {
            link?.invalidate()
            link = nil
            finish(frames)
        }
    }
}

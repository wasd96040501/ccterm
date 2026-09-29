import AppKit
import QuartzCore

/// Reads what CoreAnimation presents, frame by frame (SPEC §13, motion).
///
/// A display link samples `presentation()` on every refresh of
/// `NSScreen.main`: the frames and opacities the render server actually
/// showed. macOS 14+.
@MainActor
public enum PresentationSampler {

    /// One display-link sample of the tracked views that are showing (in the
    /// window, not hidden): their presented frames, in the ancestor's
    /// coordinates, and their presented opacities.
    public struct Frame {
        public let elapsed: TimeInterval
        public let frames: [ObjectIdentifier: CGRect]
        public let opacities: [ObjectIdentifier: CGFloat]

        public init(
            elapsed: TimeInterval, frames: [ObjectIdentifier: CGRect], opacities: [ObjectIdentifier: CGFloat]
        ) {
            self.elapsed = elapsed
            self.frames = frames
            self.opacities = opacities
        }
    }

    /// Samples `views` on every refresh for `duration`. `ancestor` should be
    /// flipped, as the list is, so the frames read top-down.
    @available(macOS 14, *)
    public static func record(_ views: [NSView], in ancestor: NSView, for duration: TimeInterval) async -> [Frame] {
        await record(in: ancestor, for: duration) { views }
    }

    /// Samples, on every refresh for `duration`, the views `views` returns
    /// then: for views that come and go while it runs.
    @available(macOS 14, *)
    public static func record(
        in ancestor: NSView, for duration: TimeInterval, views: @escaping @MainActor () -> [NSView]
    ) async -> [Frame] {
        await withCheckedContinuation { (done: CheckedContinuation<[Frame], Never>) in
            let recorder = DisplayLinkRecorder(views: views, ancestor: ancestor, duration: duration) { frames in
                done.resume(returning: frames)
            }
            recorder.start()
        }
    }

    /// `view`'s presented frame in `ancestor`'s coordinates, from its layer's
    /// `presentation()` and every presented ancestor between them.
    public static func presentedFrame(of view: NSView, in ancestor: NSView) -> CGRect {
        guard let layer = view.layer, let target = ancestor.layer else {
            preconditionFailure("presentedFrame needs layer-backed views")
        }
        let presented = layer.presentation() ?? layer
        let into = target.presentation() ?? target
        return into.convert(presented.bounds, from: presented)
    }

    /// `view`'s own presented opacity.
    public static func presentedOpacity(of view: NSView) -> CGFloat {
        guard let layer = view.layer else { preconditionFailure("presentedOpacity needs a layer-backed view") }
        return CGFloat((layer.presentation() ?? layer).opacity)
    }
}

/// The display link's target: an `NSObject`, which `NSScreen.displayLink`
/// requires. It keeps itself alive through the link until `duration` passes.
@available(macOS 14, *)
@MainActor
private final class DisplayLinkRecorder: NSObject {

    private let views: @MainActor () -> [NSView]
    private let ancestor: NSView
    private let duration: TimeInterval
    private let finish: ([PresentationSampler.Frame]) -> Void
    private var frames: [PresentationSampler.Frame] = []
    private var link: CADisplayLink?
    private var start0: CFTimeInterval = 0

    init(
        views: @escaping @MainActor () -> [NSView], ancestor: NSView, duration: TimeInterval,
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
        var frames: [ObjectIdentifier: CGRect] = [:]
        var opacities: [ObjectIdentifier: CGFloat] = [:]
        for view in views() {
            // A view out of the window or hidden shows nothing, wherever its
            // layer is.
            guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.layer != nil else { continue }
            frames[ObjectIdentifier(view)] = PresentationSampler.presentedFrame(of: view, in: ancestor)
            opacities[ObjectIdentifier(view)] = PresentationSampler.presentedOpacity(of: view)
        }
        self.frames.append(PresentationSampler.Frame(elapsed: elapsed, frames: frames, opacities: opacities))
        if elapsed >= duration {
            link?.invalidate()
            link = nil
            finish(self.frames)
        }
    }
}

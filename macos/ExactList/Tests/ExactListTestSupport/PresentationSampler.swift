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

    /// Freezes time on `root`, from the next animation added underneath it.
    public init(freezing root: CALayer) {
        fatalError("unimplemented: test support")
    }

    /// Moves the frozen time to `seconds` after the freeze, and flushes.
    public func scrub(to seconds: TimeInterval) {
        fatalError("unimplemented: test support")
    }

    /// `view`'s presented frame in `ancestor`'s coordinates, from its layer's
    /// `presentation()` and every presented ancestor between them.
    public func presentedFrame(of view: NSView, in ancestor: NSView) -> CGRect {
        fatalError("unimplemented: test support")
    }

    /// `view`'s presented opacity.
    public func presentedOpacity(of view: NSView) -> Float {
        fatalError("unimplemented: test support")
    }

    /// Releases the freeze.
    public func thaw() {
        fatalError("unimplemented: test support")
    }

    /// One display-link sample: the presented frames of the tracked views, in
    /// `ancestor`'s coordinates.
    public struct Frame {
        public let elapsed: TimeInterval
        public let frames: [ObjectIdentifier: CGRect]
    }

    /// Samples `views` on every refresh for `duration`, without freezing time.
    @available(macOS 14, *)
    public static func record(_ views: [NSView], in ancestor: NSView, for duration: TimeInterval) async -> [Frame] {
        fatalError("unimplemented: test support")
    }
}

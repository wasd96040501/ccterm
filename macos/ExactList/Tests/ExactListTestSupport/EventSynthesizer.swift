import AppKit

/// Real `NSEvent`s, delivered as `NSWindow` delivers them (S4, K1).
///
/// Clicks and keys are built with the window's number and go through
/// `NSWindow.sendEvent(_:)`. A scroll-wheel event can only be built from a
/// `CGEvent`, which carries no window, and `sendEvent` drops it (measured). So
/// it is routed the way the window routes a wheel: to the view under the point
/// (`hitTest`), whose responder chain carries it up to the scroll view.
@MainActor
public enum EventSynthesizer {

    /// A scroll-wheel event with a gesture phase (trackpad) or none (wheel), at
    /// `point` in the window, by `deltaY` points.
    public static func scroll(
        in window: NSWindow, at point: NSPoint, deltaY: CGFloat, phase: NSEvent.Phase
    ) {
        fatalError("unimplemented: test support")
    }

    /// A key press with `characters` and `keyCode`, to the window's first
    /// responder.
    public static func key(in window: NSWindow, characters: String, keyCode: UInt16) {
        fatalError("unimplemented: test support")
    }

    /// A left mouse down and up at `point` in the window.
    public static func click(in window: NSWindow, at point: NSPoint) {
        fatalError("unimplemented: test support")
    }
}

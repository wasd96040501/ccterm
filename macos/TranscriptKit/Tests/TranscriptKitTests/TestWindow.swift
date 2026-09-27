import AppKit

/// The one way a test here puts a view in a window: a real window the window
/// server composites, which never takes the focus.
///
/// - **Composited.** Parked hanging off the bottom-left corner of the main
///   screen with a single point showing, opaque. The window server only
///   composites — and only captures — a window that overlaps a display; one
///   point is enough for all of it. So what a test lays out is what the window
///   server draws, display links tick for it, and `WindowCapture` can take it as
///   it is without moving it.
/// - **Never focused.** Ordered front, never made key, and the application is
///   `.prohibited` and never activated, so whatever the person at the machine is
///   doing keeps the focus. Measured, not assumed: the frontmost application
///   stayed the same through the whole suite.
/// - **The size asked for, on any machine.** `NSWindow`'s initialiser puts a new
///   window on a screen and shrinks it to fit one too small; the frame is set
///   again after init, and `UnconstrainedWindow` keeps `orderFront` from pulling
///   it back. A 1024×768 CI display once handed the scroll tests a viewport 78
///   points short.
///
/// No logic beyond that sequence (`CLAUDE.md` §5): what goes in the window is
/// the test's business.
@MainActor
enum TestWindow {

    static func make(contentSize size: NSSize) -> NSWindow {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = UnconstrainedWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        print("DIAG window init frame=\(window.frame) number=\(window.windowNumber)")  // DIAG
        park(window, contentSize: size)
        window.orderFront(nil)
        return window
    }

    /// Hangs the window off the main screen's bottom-left corner, one point
    /// showing. Also what `WindowCapture` calls, after a test has moved one.
    static func park(_ window: NSWindow, contentSize size: NSSize? = nil) {
        let screen = (window.screen ?? NSScreen.main)?.frame ?? .zero
        let content = size ?? window.contentLayoutRect.size
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(
            x: screen.minX + 1 - frame.width, y: screen.minY + 1 - frame.height)
        window.setFrame(frame, display: false)
        window.alphaValue = 1
    }
}

/// A window AppKit does not move back onto a screen.
///
/// `orderFront` constrains a titled window's frame to the screen it lands on,
/// which is right for a window someone will look at and wrong for one a test
/// mounts: the size and the place are the test's input. Returning the frame
/// unchanged is the documented hook for exactly that.
private final class UnconstrainedWindow: NSWindow {

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

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
    /// `point` in the window. A positive `deltaY` scrolls toward the end: the
    /// offset grows, as when the reader's fingers move up.
    public static func scroll(
        in window: NSWindow, at point: NSPoint, deltaY: CGFloat, phase: NSEvent.Phase
    ) {
        guard
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-deltaY.rounded()),
                wheel2: 0, wheel3: 0)
        else { preconditionFailure("CGEvent refused a scroll-wheel event") }
        if !phase.isEmpty {
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        guard let event = NSEvent(cgEvent: cgEvent), let target = window.contentView?.hitTest(point) else {
            preconditionFailure("no view under \(point) to take the wheel")
        }
        target.scrollWheel(with: event)
    }

    /// A key press with `characters` and `keyCode`, to the window's first
    /// responder.
    public static func key(in window: NSWindow, characters: String, keyCode: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { preconditionFailure("NSEvent refused a key event") }
            window.sendEvent(event)
        }
    }

    /// A left mouse down and up at `point` in the window, delivered to the view
    /// under it, which passes it up the responder chain.
    ///
    /// Through `hitTest`, like the wheel: a test process is never the active
    /// app, so its windows can't become key, and `NSWindow.sendEvent(_:)`
    /// spends a click in a window that isn't key on activating it (measured).
    /// The up is posted to the queue before the down is sent, so a view that
    /// tracks the press in a loop of its own finds it waiting.
    public static func click(in window: NSWindow, at point: NSPoint) {
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { preconditionFailure("NSEvent refused a mouse event") }
            return event
        }
        guard let target = window.contentView?.hitTest(point) else {
            preconditionFailure("no view under \(point) to take the click")
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        target.mouseDown(with: mouse(.leftMouseDown))
    }
}

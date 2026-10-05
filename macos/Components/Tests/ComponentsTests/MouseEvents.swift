import AppKit

extension NSView {
    /// The view the window's hit test finds at `point` (in this view's
    /// coordinates; its middle by default) — the view a click there goes to.
    /// A test presses a control by asserting it is what's under the pointer,
    /// then `performClick(_:)`: synthetic mouse events don't drive a control's
    /// tracking under XCTest, where no mouse button is ever really down.
    func hitInWindow(at point: NSPoint? = nil) -> NSView? {
        guard let window, let content = window.contentView else { return nil }
        let location = convert(point ?? NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        return content.hitTest(content.convert(location, from: nil))
    }
}

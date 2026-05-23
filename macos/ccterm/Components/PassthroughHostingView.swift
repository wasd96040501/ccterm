import AppKit
import SwiftUI

/// `NSHostingView` subclass that lets clicks + cursor through transparent
/// SwiftUI areas. Used for overlay surfaces that sit on top of AppKit
/// views (the transcript `NSTableView`) but should only intercept events
/// where the SwiftUI tree actually has interactive content.
///
/// **Hit-test**: `super.hitTest(point)` returns the deepest SwiftUI
/// subview that contains the point, or `self` if no subview claims it
/// (i.e. the point lands in a transparent area like a `Spacer`). We
/// override to nil out the `self` case, so AppKit continues searching
/// siblings (the scrim, then the table below).
///
/// **Cursor**: `NSHostingView` registers a default arrow cursor rect
/// over its full bounds via `resetCursorRects()`. That rect wins
/// against the table's I-beam / pointing-hand rects underneath. We
/// override `resetCursorRects()` to no-op. SwiftUI's interactive
/// elements (text field caret, button hovers) use `NSTrackingArea`
/// with `.cursorUpdate` — a different API — so their cursor styling
/// is unaffected.
///
/// PR #181 attempted the same goal by *wrapping* the hosting view in
/// an outer `NSView` whose `hitTest` returned nil. That fixed clicks
/// but couldn't suppress the inner hosting view's arrow-cursor rect
/// (the wrapper had no access), so #190 reverted it. The subclass
/// here addresses both at the hosting view itself.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    override func resetCursorRects() {
        // Intentionally empty: don't install the default arrow cursor
        // rect over our full bounds. SwiftUI elements that want a
        // specific cursor use tracking areas, not cursor rects, so
        // their behavior is preserved.
    }
}

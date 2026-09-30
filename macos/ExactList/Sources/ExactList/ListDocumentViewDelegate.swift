import AppKit

/// What `ListDocumentView` asks and reports: keys (SPEC K1), AppKit's overdraw
/// request (P1), and the accessibility table's rows (X1–X3).
@MainActor
protocol ListDocumentViewDelegate: AnyObject {

    /// A key binding's command. `true` if the delegate or the list's own
    /// scrolling handled it; `false` passes the key on as the event (K1).
    func documentView(_ documentView: ListDocumentView, doCommandBy selector: Selector) -> Bool

    /// AppKit asked for `rect` to be prepared for responsive scrolling (P1).
    func documentView(_ documentView: ListDocumentView, prepareContentIn rect: NSRect)

    /// `n`, for `accessibilityRowCount()` (X1).
    func numberOfAccessibilityRows(in documentView: ListDocumentView) -> Int

    /// Row `row`'s accessibility element: its container if mounted, otherwise
    /// an `UnmountedRowElement` (X2, X3).
    func documentView(_ documentView: ListDocumentView, accessibilityRowAt row: Int) -> Any

    /// The rows intersecting `U` (X1).
    func accessibilityVisibleRows(in documentView: ListDocumentView) -> Range<Int>
}

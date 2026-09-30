import AppKit

/// The accessibility row for a row with no container (SPEC X3): role `.row`,
/// its index, and its frame. Focusing it scrolls it into view, which mounts
/// the row.
///
/// Created on demand and dropped when not needed; only the row number is kept,
/// and commits renumber it (X4).
final class UnmountedRowElement: NSAccessibilityElement {

    /// Weak: the list owns the elements it hands out.
    weak var delegate: UnmountedRowElementDelegate?

    var row: Int

    init(row: Int, parent: ListDocumentView) {
        self.row = row
        super.init()
        setAccessibilityParent(parent)
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .row
    }

    override func accessibilityIndex() -> Int {
        row
    }

    /// The accessibility server calls on the main thread; this class isn't
    /// main-actor-isolated only because `NSAccessibilityElement` isn't.
    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { delegate?.screenFrame(ofAccessibilityRow: row) ?? .zero }
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        guard accessibilityFocused else { return }
        MainActor.assumeIsolated { delegate?.scrollAccessibilityRowToVisible(row) }
    }
}

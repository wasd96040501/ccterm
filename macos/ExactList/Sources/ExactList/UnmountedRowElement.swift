import AppKit

/// The accessibility row for a row with no container (SPEC X3): role `.row`,
/// its index, and its frame. Focusing it scrolls it into view, which mounts
/// the row.
///
/// Created on demand and dropped when not needed; only the row number is kept,
/// and commits renumber it (X4).
final class UnmountedRowElement: NSAccessibilityElement {

    /// Weak: the list owns the elements it hands out.
    weak var owner: UnmountedRowElementOwner?

    var row: Int

    init(row: Int, parent: ListDocumentView) {
        fatalError("unimplemented: SPEC X3")
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        fatalError("unimplemented: SPEC X2")
    }

    override func accessibilityIndex() -> Int {
        fatalError("unimplemented: SPEC X2")
    }

    override func accessibilityFrame() -> NSRect {
        fatalError("unimplemented: SPEC X2")
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        fatalError("unimplemented: SPEC X3")
    }
}

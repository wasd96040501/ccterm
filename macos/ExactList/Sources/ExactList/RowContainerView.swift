import AppKit

/// Where a mounted row sits: `NSTableRowView`'s counterpart, kept internal
/// (SPEC P5).
///
/// It carries the clipping and the animations of §8, so the host's view and
/// layer never get either. The hosted view fills the container's width at the
/// row's final height, aligned to the top; the container clips it to the
/// presented height (M2). It is also the row's accessibility element (X2).
final class RowContainerView: NSView {

    /// The row this container shows, in the current numbering. −1 once it is
    /// animating out after a removal (M10, P6).
    var row: Int

    /// The host's view, or `nil` while the container is in no row.
    private(set) var hostedView: NSView?

    init(row: Int) {
        fatalError("unimplemented: SPEC P5")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    /// Puts `view` in the container, sized to `width × height`, and returns the
    /// view it replaces, if any (U6).
    func host(_ view: NSView, height: CGFloat) -> NSView? {
        fatalError("unimplemented: SPEC P2, U6")
    }

    /// Takes the hosted view out, for the pool (P3).
    func unhost() -> NSView? {
        fatalError("unimplemented: SPEC P3")
    }

    /// Lays the hosted view out at the row's final height, whatever the
    /// container's presented height is (M2).
    override func layout() {
        fatalError("unimplemented: SPEC M2")
    }

    // MARK: - Accessibility row (X2)

    override func isAccessibilityElement() -> Bool {
        fatalError("unimplemented: SPEC X2")
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        fatalError("unimplemented: SPEC X2")
    }

    override func accessibilityIndex() -> Int {
        fatalError("unimplemented: SPEC X2")
    }

    override func accessibilityChildren() -> [Any]? {
        fatalError("unimplemented: SPEC X2")
    }
}

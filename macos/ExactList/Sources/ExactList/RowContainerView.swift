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

    /// The row's height as last measured: the hosted view's height, whatever
    /// the container's own frame is doing (a removed row's frame ends at 0).
    private var hostedHeight: CGFloat = 0

    init(row: Int) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    /// Puts `view` in the container, sized to `width × height`, and returns the
    /// view it replaces, if any (U6).
    func host(_ view: NSView, height: CGFloat) -> NSView? {
        hostedHeight = height
        let replaced = hostedView === view ? nil : hostedView
        if replaced != nil || hostedView == nil {
            replaced?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            addSubview(view)
            hostedView = view
        }
        // Now, not at the next layout: a commit's frames are final when it
        // returns (U1), and a pooled view still has its last row's frame.
        view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        return replaced
    }

    /// Takes the hosted view out, for the pool (P3).
    func unhost() -> NSView? {
        let view = hostedView
        view?.removeFromSuperview()
        hostedView = nil
        return view
    }

    /// Lays the hosted view out at the row's final height, whatever the
    /// container's presented height is (M2).
    override func layout() {
        super.layout()
        hostedView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: hostedHeight)
    }

    // MARK: - Accessibility row (X2)

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .row
    }

    override func accessibilityIndex() -> Int {
        row
    }

    override func accessibilityChildren() -> [Any]? {
        hostedView.map { NSAccessibility.unignoredChildren(from: [$0]) }
    }
}

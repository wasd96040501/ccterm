import AppKit

/// Where a mounted row sits: `NSTableRowView`'s counterpart, kept internal
/// (SPEC P5).
///
/// It carries the motion of §8: `MotionAnimator` sets its frame and opacity on
/// every frame, and moves the hosted view inside it for a slide (M9), which
/// the container clips. The hosted view fills the container at every height
/// (P2), and gets nothing but its frame (P5). It is also the row's
/// accessibility element (X2).
final class ListRowView: NSView {

    /// The row this container shows, in the current numbering. −1 once it is
    /// animating out after a removal (M10, P6), and while it is a hidden spare
    /// in no row (P3).
    var row: Int

    /// The host's view, or `nil` while the container is in no row.
    private(set) var hostedView: NSView?

    /// Where the hosted view sits in the container: zero, except while a slide
    /// moves it (M9).
    var contentOffset: CGPoint = .zero {
        didSet { if contentOffset != oldValue { layOutHostedView() } }
    }

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

    /// Puts `view` in the container, filling it, and returns the view it
    /// replaces, if any (U6).
    func host(_ view: NSView) -> NSView? {
        let replaced = hostedView === view ? nil : hostedView
        if replaced != nil || hostedView == nil {
            replaced?.removeFromSuperview()
            // A pooled view may still sit in the container its last row left,
            // hidden (P3): that container lets go of it, or reusing the
            // container later would take the view out of this row.
            if let holder = view.superview as? ListRowView, holder !== self { _ = holder.unhost() }
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            addSubview(view)
            hostedView = view
        }
        // Now, not at the next layout: a pooled view still has its last row's
        // frame, and a commit's frames are set when it returns (U1).
        layOutHostedView()
        return replaced
    }

    /// Takes the hosted view out, for the pool (P3).
    func unhost() -> NSView? {
        let view = hostedView
        view?.removeFromSuperview()
        hostedView = nil
        return view
    }

    /// The hosted view follows the container's size on every frame of a
    /// motion, synchronously, so the view is drawn at each height (M2, P2).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOutHostedView()
    }

    private func layOutHostedView() {
        guard let view = hostedView else { return }
        let frame = NSRect(origin: contentOffset, size: bounds.size)
        if view.frame != frame { view.frame = frame }
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

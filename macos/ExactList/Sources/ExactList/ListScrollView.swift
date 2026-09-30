import AppKit

/// The list's scroll view: the fixed configuration (SPEC L11), and the place
/// where width and viewport changes are learned of (W1, V1, V2).
///
/// It reports from `tile()` because that is where the clip view gets its frame,
/// before the document's rows are displayed at it. That is the same point where
/// Telegram's macOS list re-measures, and not inside the table's own tiling.
final class ListScrollView: NSScrollView {

    /// Weak: the list owns this scroll view.
    weak var delegate: ListScrollViewDelegate?

    /// Installs a `ListClipView` and the L11 configuration.
    init(clipView: ListClipView) {
        super.init(frame: .zero)
        contentView = clipView
        hasVerticalScroller = true
        hasHorizontalScroller = false
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
        borderType = .noBorder
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The style the host pinned, or `nil` to follow the system setting (L11).
    var pinnedScrollerStyle: NSScroller.Style? {
        didSet { super.scrollerStyle = pinnedScrollerStyle ?? NSScroller.preferredScrollerStyle }
    }

    /// Overridden both ways, the AppKit recipe for pinning it: AppKit writes the
    /// system's style here whenever the setting changes, and reads it back to
    /// decide whether the scroller takes room from the clip view.
    override var scrollerStyle: NSScroller.Style {
        get { pinnedScrollerStyle ?? super.scrollerStyle }
        set { super.scrollerStyle = pinnedScrollerStyle ?? newValue }
    }

    override func tile() {
        super.tile()
        delegate?.listScrollViewDidTile(self)
    }
}

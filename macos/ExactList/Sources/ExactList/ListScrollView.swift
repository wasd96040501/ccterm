import AppKit

/// The list's scroll view: the fixed configuration (SPEC L11), and the place
/// where width and viewport changes are learned of (W1, V1, V2).
///
/// It reports from `tile()` because that is where the clip view gets its frame,
/// before the document's rows are displayed at it. That is the same point where
/// Telegram's macOS list re-measures, and not inside the table's own tiling.
final class ListScrollView: NSScrollView {

    /// Weak: the list owns this scroll view.
    weak var owner: ListScrollViewOwner?

    /// Installs a `ListClipView` and the L11 configuration.
    init(clipView: ListClipView) {
        fatalError("unimplemented: SPEC L11")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func tile() {
        fatalError("unimplemented: SPEC W1")
    }
}

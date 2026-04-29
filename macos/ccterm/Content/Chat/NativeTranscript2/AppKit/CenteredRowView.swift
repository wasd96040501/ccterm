import AppKit

/// Custom `NSTableRowView` that centers its single column subview at a
/// clamped width (`BlockStyle.minLayoutWidth ... maxLayoutWidth`).
///
/// The row itself spans the full table width — that's what keeps the
/// `NSScrollView`'s overlay scroller at the document's right edge and keeps
/// `NSTableView`'s tile/auto-size machinery untouched. Centering happens by
/// repositioning the cell view inside `layout()`, which is exactly the
/// `NSTableRowView` hook for arranging column views (the same path AppKit's
/// own indent-aware row views use).
///
/// Why this and not a wrapper `documentView`: wrapping the table inside a
/// centering NSView breaks `NSScrollView.tile()`'s coordination with
/// `NSTableView`'s automatic content-height tracking — you have to
/// re-implement that. Subclassing the row view costs nothing and keeps
/// every other AppKit behavior (live resize, scroller, autoscroll, row
/// reuse) on the default path.
final class CenteredRowView: NSTableRowView {
    override func layout() {
        super.layout()
        // Cell view is added by `NSTableView` after `viewFor` returns; on a
        // freshly-created row that hasn't been populated yet there's nothing
        // to position.
        guard let cell = subviews.first(where: { $0 is BlockCellView }) else { return }
        let w = BlockStyle.clampedLayoutWidth(forRowWidth: bounds.width)
        let x = BlockStyle.cellOriginX(forRowWidth: bounds.width)
        cell.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
    }
}

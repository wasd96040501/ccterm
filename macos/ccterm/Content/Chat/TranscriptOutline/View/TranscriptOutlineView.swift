import AppKit

/// Minimal `NSOutlineView` subclass. The disclosure triangle stays fully
/// native (AppKit's own button, drawing and rotation animation); the only
/// customization is *where* it sits: `frameOfOutlineCell(atRow:)` is
/// Apple's documented override point for the outline cell's frame, and we
/// use it to move the button out of the window-left gutter into the
/// centered content column — at the row's content x (so a level-0 group
/// chevron aligns with markdown's text edge) and vertically centered on
/// the fixed header title band.
final class TranscriptOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        // Non-expandable rows report .zero — nothing to place.
        guard frame != .zero else { return frame }
        let level = max(0, self.level(forRow: row))
        frame.origin.x = TranscriptOutlineMetrics.contentX(
            forRowWidth: bounds.width, level: level, hasChevronSlot: false)
        // Center the button on the header title band rather than the
        // whole row (rows carry asymmetric L1/L2 padding).
        let padTop =
            level == 0
            ? TranscriptOutlineMetrics.groupHeaderPadding.top
            : TranscriptOutlineMetrics.toolHeaderPadding.top
        frame.origin.y += padTop
        frame.size.height = BlockStyle.toolHeaderHeight
        return frame
    }
}

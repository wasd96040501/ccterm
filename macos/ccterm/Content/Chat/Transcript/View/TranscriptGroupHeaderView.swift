import AppKit

/// Draws a tool-group header row — the aggregated narration title for a
/// run of adjacent tool calls. Title-only chrome: no selectable text, no
/// links, nothing to click.
///
/// A `MarkdownBlockView` subclass even though it isn't a markdown block:
/// the base class's machinery (layer-cached draw, centered content
/// column, cursor rects) is what every row in this table needs, and
/// inheriting it keeps the header row's geometry identical to its
/// neighbours'.
final class TranscriptGroupHeaderView: MarkdownBlockView {
    private var header: TranscriptGroupHeaderLayout?

    func configure(_ measure: TranscriptGroupHeaderLayout, width: CGFloat) {
        header = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { header?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { header?.measuredWidth ?? 0 }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        header?.draw(in: ctx, origin: origin)
    }
}

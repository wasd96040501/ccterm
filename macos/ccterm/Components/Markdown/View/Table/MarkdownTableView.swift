import AppKit

/// Draws one GFM table — CSS-like column allocation, self-drawn grid,
/// per-cell text selection.
final class MarkdownTableView: MarkdownBlockView {
    private var table: TableLayout?

    func configure(_ measure: TableLayout, width: CGFloat) {
        table = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { table?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { table?.measuredWidth ?? 0 }
    override var selectionAdapter: SelectionAdapter? { table?.selectionAdapter }

    override var interactiveHits: [InteractiveHit] {
        // Cell links are already in table-local coords after `make`.
        (table?.links ?? []).map {
            InteractiveHit(rect: $0.rect, action: .openURL($0.url))
        }
    }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        table?.draw(in: ctx, origin: origin)
    }
}

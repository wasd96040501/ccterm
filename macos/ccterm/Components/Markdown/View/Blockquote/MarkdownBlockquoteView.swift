import AppKit

/// Draws one blockquote — a left accent bar plus the quoted text.
final class MarkdownBlockquoteView: MarkdownBlockView {
    private var quote: BlockquoteLayout?

    func configure(_ measure: BlockquoteLayout, width: CGFloat) {
        quote = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { quote?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { quote?.measuredWidth ?? 0 }
    override var selectionAdapter: SelectionAdapter? { quote?.selectionAdapter }

    override var interactiveHits: [InteractiveHit] {
        (quote?.links ?? []).map {
            InteractiveHit(rect: $0.rect, action: .openURL($0.url))
        }
    }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        quote?.draw(in: ctx, origin: origin)
    }
}

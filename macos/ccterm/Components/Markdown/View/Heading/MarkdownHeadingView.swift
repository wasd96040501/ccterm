import AppKit

/// Draws one markdown heading (`#` … `######`). Same Core Text measure
/// type as the paragraph view; the difference is the typography
/// `BlockStyle.headingAttributed(level:inlines:)` applies per level.
final class MarkdownHeadingView: MarkdownBlockView {
    private var text: TextLayout?

    func configure(_ measure: TextLayout, width: CGFloat) {
        text = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { text?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { text?.measuredWidth ?? 0 }
    override var selectionAdapter: SelectionAdapter? { text?.selectionAdapter }

    override var interactiveHits: [InteractiveHit] {
        (text?.links ?? []).map {
            InteractiveHit(rect: $0.rect, action: .openURL($0.url))
        }
    }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        text?.draw(in: ctx, origin: origin)
    }
}

import AppKit

/// Draws a thematic break (`---`) — a single hairline rule. Nothing to
/// select, nothing to click.
final class MarkdownThematicBreakView: MarkdownBlockView {
    private var rule: ThematicBreakLayout?

    func configure(_ measure: ThematicBreakLayout, width: CGFloat) {
        rule = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { rule?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { rule?.measuredWidth ?? 0 }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        rule?.draw(in: ctx, origin: origin)
    }
}

import AppKit

/// Draws a right-aligned strip of user-attached image thumbnails, one
/// clickable chip each. Not text, so nothing to select.
final class MarkdownUserAttachmentsView: MarkdownBlockView {
    private var strip: UserAttachmentsLayout?

    func configure(_ measure: UserAttachmentsLayout, width: CGFloat) {
        strip = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { strip?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { strip?.measuredWidth ?? 0 }
    override var interactiveHits: [InteractiveHit] { strip?.interactiveHits ?? [] }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        // The measure can draw one chip in a hovered state; that needs a
        // tracking area this view doesn't install yet, so every chip is
        // drawn resting.
        strip?.draw(in: ctx, origin: origin, hoveredAction: nil)
    }
}

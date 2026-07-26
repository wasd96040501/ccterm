import AppKit

/// Draws one inline image, aspect-fit into the content column and
/// centered. Not selectable (an image carries no text positions).
///
/// Named with the `Markdown` prefix so it never reads as AppKit's
/// `NSImageView`.
final class MarkdownImageView: MarkdownBlockView {
    private var picture: ImageLayout?

    func configure(_ measure: ImageLayout, width: CGFloat) {
        picture = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { picture?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { picture?.measuredWidth ?? 0 }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        picture?.draw(in: ctx, origin: origin)
    }
}

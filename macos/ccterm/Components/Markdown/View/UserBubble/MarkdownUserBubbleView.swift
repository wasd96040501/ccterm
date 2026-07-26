import AppKit

/// Draws a right-aligned user message bubble — rounded fill, truncation
/// past a line threshold, a chevron affordance when truncated, and a
/// badge when the message is still queued.
final class MarkdownUserBubbleView: MarkdownBlockView {
    private var bubble: UserBubbleLayout?

    func configure(_ measure: UserBubbleLayout, width: CGFloat) {
        bubble = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { bubble?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { bubble?.measuredWidth ?? 0 }
    override var selectionAdapter: SelectionAdapter? { bubble?.selectionAdapter }

    /// The bubble is right-aligned and narrower than the column, so the
    /// I-beam is confined to it — empty gutter left of the bubble keeps
    /// the default arrow.
    override var iBeamRect: CGRect? { bubble?.bubbleRect }

    override var interactiveHits: [InteractiveHit] {
        guard let rect = bubble?.chevronHitRect else { return [] }
        return [InteractiveHit(rect: rect, action: .openUserBubbleSheet)]
    }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        bubble?.draw(in: ctx, origin: origin)
    }
}

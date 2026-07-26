import AppKit

/// Draws one markdown paragraph. Its measure is a `TextLayout` — a
/// Core Text typeset it shares with the heading view, but nothing wider:
/// each block view owns its own measure type.
///
/// The measure is made and cached by the host, not by the view, so a row
/// height can be answered before any view exists and a typeset survives
/// view reuse:
///
/// ```swift
/// let measure = TextLayout.make(
///     attributed: BlockStyle.paragraphAttributed(inlines: inlines), maxWidth: w)
/// view.configure(measure, width: w)
/// ```
final class MarkdownParagraphView: MarkdownBlockView {
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

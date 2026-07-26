import AppKit

/// Draws one fenced code block: rounded card, language badge, copy
/// button, and the code text itself.
///
/// **Highlighting is injected, never owned.** `CodeBlockLayout.make`
/// takes optional pre-computed `[SyntaxToken]`; absent → plain text. The
/// async tokenizer lives in the adopter, not in this view.
final class MarkdownCodeBlockView: MarkdownBlockView {
    private var card: CodeBlockLayout?

    func configure(_ measure: CodeBlockLayout, width: CGFloat) {
        card = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { card?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { card?.measuredWidth ?? 0 }
    override var selectionAdapter: SelectionAdapter? { card?.selectionAdapter }

    override var interactiveHits: [InteractiveHit] {
        guard let card else { return [] }
        var hits = card.links.map {
            InteractiveHit(rect: $0.rect, action: .openURL($0.url))
        }
        if let copy = card.copy {
            hits.append(
                InteractiveHit(
                    rect: copy.hitRect, action: .copy(id: copy.id, text: copy.text)))
        }
        return hits
    }

    /// The card's fill is opaque, so it has to land before the selection
    /// band — otherwise the highlight would be painted over.
    override func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        card?.drawBackplate(in: ctx, origin: origin)
    }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        guard let card else { return }
        card.draw(in: ctx, origin: origin)
        // The copy glyph paints last so it sits above the code text.
        // Hover / post-click flash need a tracking area this view doesn't
        // install yet — the icon is drawn in its resting state.
        card.copy?.draw(in: ctx, origin: origin, hovered: false, flashing: false)
    }
}

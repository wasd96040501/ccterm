import AppKit

/// Immutable blockquote layout — pure function of `([InlineNode], maxWidth)`.
///
/// **No container chrome**: just a left accent bar and indented text.
/// Matches the prior renderer's blockquote treatment (and Slack /
/// Discord / GitHub conventions): a quote is a margin annotation, not
/// a standalone container, so adding a bg fill or rounded corner gives
/// it more visual weight than its semantic role deserves.
///
/// `@unchecked Sendable` for the same reason as `TextLayout` — the
/// embedded layout owns `CTLine` references.
struct BlockquoteLayout: @unchecked Sendable {
    let text: TextLayout
    /// Left bar in layout-local coords (y-down). Height matches the
    /// inner text height so the bar starts and ends with the glyphs,
    /// not with the row pad.
    let barRect: CGRect
    /// Top-left of the text region — equals
    /// `(blockquoteBarWidth + blockquoteBarGap, 0)`.
    let textOriginInLayout: CGPoint

    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    /// Link hit zones already projected into layout-local coords.
    var links: [TextLayout.LinkHit] {
        text.links.map { hit in
            TextLayout.LinkHit(
                rect: hit.rect.offsetBy(dx: textOriginInLayout.x,
                                        dy: textOriginInLayout.y),
                url: hit.url)
        }
    }

    nonisolated static func make(inlines: [InlineNode], maxWidth: CGFloat) -> BlockquoteLayout {
        guard maxWidth > 0 else {
            return BlockquoteLayout(
                text: .empty,
                barRect: .zero,
                textOriginInLayout: .zero,
                totalHeight: 0,
                measuredWidth: 0)
        }
        let leftInset = BlockStyle.blockquoteBarWidth + BlockStyle.blockquoteBarGap
        let textMaxWidth = max(1, maxWidth - leftInset)
        let attributed = BlockStyle.paragraphAttributed(inlines: inlines)
        let text = TextLayout.make(attributed: attributed, maxWidth: textMaxWidth)

        let textOrigin = CGPoint(x: leftInset, y: 0)
        let bar = CGRect(
            x: 0, y: 0,
            width: BlockStyle.blockquoteBarWidth,
            height: text.totalHeight)

        return BlockquoteLayout(
            text: text,
            barRect: bar,
            textOriginInLayout: textOrigin,
            totalHeight: text.totalHeight,
            measuredWidth: maxWidth)
    }

    // MARK: - Selection adapter

    /// Wraps the inner `TextLayout`'s adapter, offsetting hit-test input
    /// and selection rects by the text region's origin.
    var selectionAdapter: SelectionAdapter {
        let inner = text.selectionAdapter
        let offset = textOriginInLayout
        return SelectionAdapter(
            fullRange: inner.fullRange,
            unitRange: inner.unitRange,
            hitTest: { p in
                inner.hitTest(CGPoint(x: p.x - offset.x, y: p.y - offset.y))
            },
            rects: { a, b in
                inner.rects(a, b).map {
                    $0.offsetBy(dx: offset.x, dy: offset.y)
                }
            },
            string: inner.string,
            wordBoundary: inner.wordBoundary)
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, origin: CGPoint) {
        // 1) Left accent bar — `cornerWidth: 1` is anti-aliasing cleanup,
        //    not a visible round (matches the prior renderer's value).
        ctx.saveGState()
        let bar = barRect.offsetBy(dx: origin.x, dy: origin.y)
        let path = CGPath(
            roundedRect: bar, cornerWidth: 1, cornerHeight: 1, transform: nil)
        ctx.setFillColor(BlockStyle.blockquoteBarColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        // 2) Text — same color and styling as a regular paragraph.
        text.draw(in: ctx, origin: CGPoint(
            x: origin.x + textOriginInLayout.x,
            y: origin.y + textOriginInLayout.y))
    }
}

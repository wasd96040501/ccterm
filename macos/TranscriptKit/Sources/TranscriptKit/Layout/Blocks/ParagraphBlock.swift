import AppKit

/// Text occupying one block of the vertical flow.
///
/// It holds no styling decisions. Fonts, colours and inline emphasis arrive
/// already resolved on the `ShapedText`, which keeps "what does bold look
/// like" in one place instead of one place per block kind — and already shaped,
/// so `measure` does nothing but break lines.
///
/// **It also claims no space of its own.** A paragraph is the baseline the
/// container's `spacing` was chosen for, so its box is exactly its glyphs and
/// two adjacent paragraphs sit `spacing` apart with neither having said
/// anything. Only the kinds that want *more* than that — a heading's `topInset`,
/// bordered blocks, rules — add to their own height.
struct ParagraphBlock: Block, @unchecked Sendable {

    let text: ShapedText

    /// Extra room **above** the text, on top of whatever the container puts
    /// between two blocks — what makes a heading a section break.
    let topInset: CGFloat

    init(_ text: ShapedText, topInset: CGFloat = 0) {
        self.text = text
        self.topInset = topInset
    }

    func measure(_ width: CGFloat) -> MeasuredBlock {
        let text = text.typeset(width: width)
        return Measured(
            text: text, textOrigin: CGPoint(x: 0, y: topInset),
            size: CGSize(width: width, height: topInset + text.size.height))
    }

    /// `size.width` is the width the paragraph was measured into, as distinct
    /// from `text.size.width` — the widest line it happened to produce. A short
    /// last line must not narrow the block, or anything aligned to its right edge
    /// would move with the text.
    struct Measured: MeasuredTextBlock, @unchecked Sendable {
        let text: TypesetText
        let textOrigin: CGPoint
        let size: CGSize

        /// One item. A paragraph is nothing but its glyphs — no fill behind them,
        /// nothing over them — so this is the shortest `paint` in the package and
        /// the one to read first.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            list.append(
                .text(text, at: CGPoint(x: origin.x + textOrigin.x, y: origin.y + textOrigin.y)))
        }
    }
}

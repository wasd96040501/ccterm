import AppKit

/// A run of text occupying one block of the vertical flow.
///
/// It holds no styling decisions. Fonts, colours and inline emphasis arrive
/// already resolved on the `NSAttributedString`, which keeps "what does bold look
/// like" in one place instead of one place per block kind.
///
/// **It also claims no space of its own.** A paragraph is the baseline the
/// container's `spacing` was chosen for, so its box is exactly its glyphs and
/// two adjacent paragraphs sit `spacing` apart with neither having said
/// anything. Only the kinds that want *more* than that — headings above
/// themselves, bordered blocks, rules — add to their own height.
struct Paragraph: Layout {

    let attributed: NSAttributedString

    init(_ attributed: NSAttributedString) {
        self.attributed = attributed
    }

    func measure(_ width: CGFloat) -> MarkdownBlock {
        let run = MarkdownTextRun.make(attributed, width: width)
        return Measured(run: run, textOrigin: .zero, size: CGSize(width: width, height: run.size.height))
    }

    /// `size.width` is the width the paragraph was measured into, as distinct
    /// from `run.size.width` — the widest line it happened to produce. A short
    /// last line must not narrow the block, or anything aligned to its right edge
    /// would move with the text.
    struct Measured: MarkdownTextBlock, @unchecked Sendable {
        let run: MarkdownTextRun
        let textOrigin: CGPoint
        let size: CGSize

        /// One item. A paragraph is nothing but its glyphs — no fill behind them,
        /// nothing over them — so this is the shortest `paint` in the package and
        /// the one to read first.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            list.append(
                .run(run, at: CGPoint(x: origin.x + textOrigin.x, y: origin.y + textOrigin.y)))
        }
    }
}

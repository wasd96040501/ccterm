import AppKit

/// A decorator: indents whatever it wraps and draws an accent bar beside it.
///
/// The whole type is the bar and the indent. Arrangement, height, hit testing,
/// selection, the offset applied to every rectangle that comes back — all belong
/// to the layout inside, and none of it is written here.
///
/// It wraps a `Layout`, not a parsed node, so it composes with *anything*: a
/// stack of markdown blocks today, a table or a host-supplied layout tomorrow.
/// The renderer this replaces modelled a blockquote as
/// `struct BlockquoteLayout { let text: TextLayout }`, so a quote containing a
/// code block was not styled badly — it could not be represented.
///
/// Note where the arithmetic is: `measure` subtracts the indent from the width it
/// was handed and passes the remainder down. The inner width never leaves this
/// function, so no caller can disagree with it.
///
/// The bar spans the content's full box, which includes whatever padding the
/// content gave itself. That is the price of a decorator that does not inspect
/// what it wraps, and it is the right price: the alternative is asking the
/// content to publish its own spacing, which is what makes a paragraph
/// responsible for something only its surroundings can know.
struct Blockquote: Layout {

    let content: Layout

    var indent: CGFloat = 14
    var barWidth: CGFloat = 3
    var barColor: NSColor = .secondaryLabelColor

    init(_ content: Layout) {
        self.content = content
    }

    func measure(_ width: CGFloat) -> MarkdownBlock {
        let inner = content.measure(max(1, width - indent))
        return Measured(
            content: inner,
            indent: indent,
            bar: CGRect(x: 0, y: 0, width: barWidth, height: inner.size.height),
            barColor: barColor,
            size: CGSize(width: width, height: inner.size.height))
    }

    struct Measured: MarkdownBlock, @unchecked Sendable {

        let content: MarkdownBlock
        let indent: CGFloat
        let bar: CGRect
        let barColor: NSColor
        let size: CGSize

        /// The bar, and then whatever the content says. `.background` for the bar
        /// because it is chrome — nothing of the content's ever overlaps it, but
        /// classifying it by what it *is* keeps the tiers meaning one thing.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            list.append(.fill(bar.offsetBy(dx: origin.x, dy: origin.y), barColor))
            content.paint(
                at: CGPoint(x: origin.x + indent, y: origin.y), dirty: dirty, into: &list)
        }

        // MARK: - Selection — all of it the content's, shifted by the indent

        var length: Int { content.length }

        func index(at point: CGPoint) -> Int {
            content.index(at: CGPoint(x: point.x - indent, y: point.y))
        }

        func rects(from: Int, to: Int) -> [CGRect] {
            content.rects(from: from, to: to).map { $0.offsetBy(dx: indent, dy: 0) }
        }

        func text(from: Int, to: Int) -> String { content.text(from: from, to: to) }
    }
}

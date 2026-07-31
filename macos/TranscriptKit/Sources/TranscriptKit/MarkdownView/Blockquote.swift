import AppKit

/// A quoted passage: a stack of arbitrary blocks, indented, with an accent bar
/// beside it.
///
/// The whole type is the bar. Everything else — arrangement, height, hit
/// testing, selection, the indent offset applied to every rectangle that comes
/// back — belongs to the `BlockStack` it wraps, and none of it is written here.
///
/// That its contents are `[Block]` rather than text is the point of the
/// exercise. The renderer this replaces modelled a blockquote as
/// `struct BlockquoteLayout { let text: TextLayout }`, so a quote containing a
/// code block or a list was not styled badly — it could not be represented.
struct Blockquote: Block {

    private let content: BlockStack
    private let barRect: CGRect
    private let barColor: NSColor

    var size: CGSize { content.size }

    /// `content` is the quoted blocks, already stacked and already indented by
    /// the style's quote indent — building it is `MarkdownLayout`'s job, since
    /// spacing quoted blocks is the same problem as spacing top-level ones.
    static func make(content: BlockStack, style: MarkdownStyle) -> Blockquote {
        Blockquote(
            content: content,
            // Spans the content's full height so the bar starts and ends with
            // the glyphs rather than with padding around them — which is why
            // the content is built without outer padding.
            barRect: CGRect(x: 0, y: 0, width: style.quoteBarWidth, height: content.size.height),
            barColor: style.secondaryColor)
    }

    func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(barColor.cgColor)
        ctx.fill(barRect.offsetBy(dx: origin.x, dy: origin.y))
        ctx.restoreGState()
        content.draw(at: origin, in: ctx, dirty: dirty)
    }

    // MARK: - Selection — all of it the stack's

    var length: Int { content.length }
    func index(at point: CGPoint) -> Int { content.index(at: point) }
    func rects(from: Int, to: Int) -> [CGRect] { content.rects(from: from, to: to) }
    func text(from: Int, to: Int) -> String { content.text(from: from, to: to) }
}

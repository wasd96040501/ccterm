import AppKit

/// A horizontal rule.
///
/// The first `MarkdownOpaqueBlock`, and the reason that protocol exists: a rule is
/// visible but holds no text, so it occupies zero positions in the index space.
/// A drag straight through one selects the paragraphs on either side and picks up
/// nothing in between — what a reader expects, and what a browser does.
struct ThematicBreak: Layout {

    var thickness: CGFloat = 1
    var color: NSColor = .separatorColor

    /// On top of the container's spacing. A thin line has no optical room of its
    /// own — a paragraph's descenders and leading give it some slack, a rule has
    /// none — so it buys six more on each side or it attaches to whichever
    /// neighbour is closer.
    var padding: CGFloat = 6

    func measure(_ width: CGFloat) -> MarkdownBlock {
        Measured(
            size: CGSize(width: width, height: thickness + padding * 2),
            thickness: thickness,
            padding: padding,
            color: color)
    }

    struct Measured: MarkdownOpaqueBlock, @unchecked Sendable {

        let size: CGSize
        let thickness: CGFloat
        let padding: CGFloat
        let color: NSColor

        func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            ctx.fill(
                CGRect(
                    x: origin.x, y: origin.y + padding, width: size.width, height: thickness))
            ctx.restoreGState()
        }
    }
}

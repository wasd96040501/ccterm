import AppKit

/// A horizontal rule — `---` in the source.
///
/// The first `OpaqueBlock`, and the reason that protocol exists: a rule is
/// visible but holds no text, so it occupies zero positions in the document's
/// index space. A drag straight through one selects the paragraphs on either
/// side and picks up nothing in between, which is what a reader expects and
/// what a browser does.
struct ThematicBreak: OpaqueBlock {

    let size: CGSize
    let color: NSColor
    let thickness: CGFloat

    /// Vertical breathing room above and below the line, included in `size`.
    private let padding: CGFloat

    static func make(
        width: CGFloat,
        thickness: CGFloat = 1,
        padding: CGFloat = 8,
        color: NSColor = .separatorColor
    ) -> ThematicBreak {
        ThematicBreak(
            size: CGSize(width: width, height: thickness + padding * 2),
            color: color,
            thickness: thickness,
            padding: padding)
    }

    func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.fill(
            CGRect(
                x: origin.x, y: origin.y + padding,
                width: size.width, height: thickness))
        ctx.restoreGState()
    }
}

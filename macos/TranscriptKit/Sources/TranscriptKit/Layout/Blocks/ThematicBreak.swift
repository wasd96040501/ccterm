import AppKit

/// A horizontal rule.
///
/// The first `MeasuredOpaqueBlock`, and the reason that protocol exists: a rule is
/// visible but holds no text, so it occupies zero positions in the index space.
/// A drag straight through one selects the paragraphs on either side and picks up
/// nothing in between — what a reader expects, and what a browser does.
struct ThematicBreak: Block {

    var thickness: CGFloat = 1

    /// `secondaryLabelColor`, not `separatorColor`. A rule in prose is a section
    /// break the author asked for, and the separator tint — a few per cent of
    /// black — reads as an accident of the background at one point thick. This
    /// used to be `separatorColor` here and be overwritten by the document's
    /// style on the way past, so what the file said and what shipped disagreed.
    var color: NSColor = .secondaryLabelColor

    /// On top of the container's spacing. A thin line has no optical room of its
    /// own — a paragraph's descenders and leading give it some slack, a rule has
    /// none — so it buys six more on each side or it attaches to whichever
    /// neighbour is closer.
    var padding: CGFloat = 6

    func measure(_ width: CGFloat) -> MeasuredBlock {
        Measured(
            size: CGSize(width: width, height: thickness + padding * 2),
            thickness: thickness,
            padding: padding,
            color: color)
    }

    struct Measured: MeasuredOpaqueBlock, @unchecked Sendable {

        let size: CGSize
        let thickness: CGFloat
        let padding: CGFloat
        let color: NSColor

        /// `.content`, not `.background`: the line *is* what this block has to
        /// say, not something sitting behind what it has to say.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            list.append(
                .fill(
                    CGRect(
                        x: origin.x, y: origin.y + padding, width: size.width, height: thickness),
                    color, phase: .content))
        }
    }
}

import AppKit

/// A run of text occupying one block of the document's vertical flow —
/// a markdown paragraph, and the same type a heading uses with a different
/// attributed string.
///
/// It holds no styling decisions of its own. Fonts, colours and inline emphasis
/// arrive already resolved on the `NSAttributedString`, which keeps "what does
/// bold look like" in one place instead of one place per block kind.
struct Paragraph: TextBlock {

    let run: TextRun

    var size: CGSize { CGSize(width: width, height: run.size.height) }

    /// The full width the paragraph occupies, as distinct from `run.size.width`
    /// — the widest line it happened to produce. A stack places blocks by the
    /// former; a short last line must not narrow the block.
    private let width: CGFloat

    static func make(_ attributed: NSAttributedString, width: CGFloat) -> Paragraph {
        Paragraph(run: .make(attributed, width: width), width: width)
    }

    func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
        run.draw(at: origin, in: ctx, dirty: dirty)
    }
}

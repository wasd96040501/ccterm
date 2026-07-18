import AppKit
import CoreText

/// Title-only header layout for the outline transcript's tool-group and
/// tool nodes. The native `NSOutlineView` disclosure triangle owns the
/// arrow, so this layout only typesets and draws the header title using
/// the shared `BlockStyle.toolHeader*` typography — no self-drawn
/// chevron, no icon, no inset (the row's horizontal padding comes from
/// the cell's `layoutOrigin.x`).
///
/// Reuses `TextLayout` for the single line and centers it inside the
/// fixed `toolHeaderHeight` band so a group header, a tool header, and
/// the adjacent code-block chrome all read at one pitch.
struct HeaderLayout: @unchecked Sendable {
    /// The typeset title line(s). Built from the shared header typography.
    let text: TextLayout
    /// Layout-local y offset that vertically centers the title inside the
    /// fixed header band.
    let textTopInset: CGFloat
    /// Fixed header-band height (`BlockStyle.toolHeaderHeight`).
    let totalHeight: CGFloat

    var measuredWidth: CGFloat { text.measuredWidth }

    static func make(title: String, maxWidth: CGFloat) -> HeaderLayout {
        let attributed = NSAttributedString(
            string: title,
            attributes: [
                .font: BlockStyle.toolHeaderFont,
                .foregroundColor: BlockStyle.toolHeaderForeground,
            ])
        let text = TextLayout.make(attributed: attributed, maxWidth: maxWidth)
        let height = BlockStyle.toolHeaderHeight
        // Center the (single-line) title in the fixed header band. Clamp
        // to 0 so a title that somehow wraps taller than the band still
        // draws from the top rather than being pushed up out of view.
        let inset = max(0, (height - text.totalHeight) / 2)
        return HeaderLayout(text: text, textTopInset: inset, totalHeight: height)
    }

    /// Draw the title into a flipped view. `origin` is the layout's
    /// top-left in view coords (the cell's `layoutOrigin`).
    func draw(in ctx: CGContext, origin: CGPoint) {
        text.draw(
            in: ctx,
            origin: CGPoint(x: origin.x, y: origin.y + textTopInset))
    }
}

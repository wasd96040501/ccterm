import AppKit

/// Immutable thematic-break layout — pure function of `maxWidth`.
///
/// Renders as a single horizontal hairline spanning the row's content
/// width. No selectable region (no glyphs to select), no link, no
/// internal payload — `RowLayout` exposes a `nil` `selectionAdapter`
/// for this kind so the cell skips the I-beam cursor and selection
/// painting paths entirely.
struct ThematicBreakLayout: Sendable {
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    nonisolated static func make(maxWidth: CGFloat) -> ThematicBreakLayout {
        ThematicBreakLayout(
            totalHeight: BlockStyle.thematicBreakHeight,
            measuredWidth: max(0, maxWidth))
    }

    /// Draws the hairline at vertical center of `(origin, totalHeight)`.
    /// `origin` is the layout's top-left in view coords (y-down, flipped
    /// table view).
    func draw(in ctx: CGContext, origin: CGPoint) {
        guard measuredWidth > 0 else { return }
        ctx.saveGState()
        ctx.setFillColor(BlockStyle.thematicBreakColor.cgColor)
        ctx.fill(CGRect(
            x: origin.x,
            y: origin.y + (totalHeight - BlockStyle.thematicBreakHeight) / 2,
            width: measuredWidth,
            height: BlockStyle.thematicBreakHeight))
        ctx.restoreGState()
    }
}

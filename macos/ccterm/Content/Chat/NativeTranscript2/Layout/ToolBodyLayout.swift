import AppKit

/// One tool's expanded body as a standalone outline leaf.
///
/// Adapts the reused `ToolGroupChildLayout` (which was designed for the
/// monolithic `toolGroup` row that painted a group header + every child
/// header + every body inside one cell) into an independent row: the
/// body is laid out in its own layout-local coordinate space with origin
/// `(0, 0)`, so the cell's `layoutOrigin` positions it directly and the
/// native outline indent expresses the hierarchy. No coupling to a group
/// header, no `ToolGroupEntryView` sliding subviews — each body owns its
/// own row/cell, so the disclosure animation is the outline's job.
///
/// The per-kind card backgrounds are painted by `drawBackplate`; the
/// glyphs + copy chrome by `draw`. Copy affordances surface through
/// `copyChromes` so the cell can register their hit zones.
struct ToolBodyLayout: @unchecked Sendable {
    let body: ToolGroupChildLayout
    /// Row content width the body was typeset at (net of horizontal
    /// padding) — the layout cache's width key compares against this.
    let measuredWidth: CGFloat

    var totalHeight: CGFloat { body.totalHeight }

    /// `rowWidth` is the full cell width; the body is typeset at
    /// `rowWidth - 2 * blockHorizontalPadding`, matching every other
    /// block kind's content inset. Highlight tokens are not wired in this
    /// round (cold render — plain code), so `highlight` is `nil`.
    static func make(child: ToolGroupBlock.Child, rowWidth: CGFloat) -> ToolBodyLayout {
        let contentWidth = max(0, rowWidth - 2 * BlockStyle.blockHorizontalPadding)
        let body = ToolGroupChildLayout.make(
            child: child,
            highlight: nil,
            originX: 0,
            originY: 0,
            maxWidth: contentWidth)
        return ToolBodyLayout(body: body, measuredWidth: contentWidth)
    }

    func drawBackplate(in ctx: CGContext, origin: CGPoint, dirtyRect: CGRect? = nil) {
        body.drawBackplate(in: ctx, origin: origin, dirtyRect: dirtyRect)
    }

    /// Glyphs + per-card copy chrome. `hoveredCopyId` drives the copy
    /// icon's hover background; the checkmark-flash set is not threaded in
    /// this round.
    func draw(
        in ctx: CGContext, origin: CGPoint,
        hoveredCopyId: UUID? = nil, dirtyRect: CGRect? = nil
    ) {
        body.draw(
            in: ctx, origin: origin,
            hoveredCopyId: hoveredCopyId,
            flashingCopyIds: [],
            dirtyRect: dirtyRect)
    }

    /// Copy affordances in layout-local coords, so the cell can register
    /// pointing-hand cursor + click dispatch through `HitAction.copy`.
    var copyChromes: [CopyChrome] { body.copyChromes }
}

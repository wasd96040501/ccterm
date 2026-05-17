import AppKit

/// Immutable layout for the trailing "running" indicator — just three
/// breathing dots at the start of the centered content band. No
/// background, no label; the dots themselves carry the entire signal.
///
/// All paint happens through `SubviewPlan.LoadingDots` so the cell
/// hosts `CAShapeLayer`s whose opacity loops run on the CoreAnimation
/// thread without re-driving `draw(_:)`. The layout reports just the
/// geometry (height, dot rects) — `draw(in:origin:)` is a no-op.
///
/// Alignment: dots start at the layout's local `x = 0`. The cell's
/// `layoutOrigin.x` shifts that to the centered band's left edge, so
/// the indicator lines up flush with where paragraphs and user
/// bubbles begin.
///
/// `selectionAdapter` is `nil` (no glyph hit testing, no copy);
/// `interactiveHits` is empty. The row is decorative.
struct LoadingPillLayout: Sendable {
    let totalHeight: CGFloat
    let measuredWidth: CGFloat
    /// Per-dot rects (top-left + size) in layout-local coords.
    let dotRects: [CGRect]

    nonisolated static func make() -> LoadingPillLayout {
        let dotSize = BlockStyle.loadingPillDotSize
        let dotGap = BlockStyle.loadingPillDotGap
        let dotsWidth = dotSize * 3 + dotGap * 2

        var rects: [CGRect] = []
        rects.reserveCapacity(3)
        for i in 0..<3 {
            let x = CGFloat(i) * (dotSize + dotGap)
            rects.append(CGRect(x: x, y: 0, width: dotSize, height: dotSize))
        }

        return LoadingPillLayout(
            totalHeight: dotSize,
            measuredWidth: dotsWidth,
            dotRects: rects)
    }

    /// No-op. The dots animate as `CAShapeLayer`s registered via
    /// `SubviewPlan.LoadingDots`; the cell bitmap has nothing to paint
    /// for this row.
    func draw(in ctx: CGContext, origin: CGPoint) {}
}

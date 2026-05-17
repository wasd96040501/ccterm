import AppKit
import CoreText

/// Immutable layout for the trailing "running" pill — a small chip
/// with three breathing dots + a "Working" label. Self-drawn here for
/// the pill background and label; the animated dots are surfaced via
/// `SubviewPlan.LoadingDots` so the cell hosts `CAShapeLayer`s whose
/// opacity animations run on the CoreAnimation thread without
/// re-driving `draw(_:)`.
///
/// Sized to its intrinsic content (dots + gap + label + padding). The
/// pill is **left-aligned** inside the layout's local coords (origin
/// `x = 0`); the cell's `layoutOrigin.x` already shifts to the
/// centered band's left edge, so the pill lands flush with the left
/// margin of the centered content column — same alignment as a
/// paragraph block on the same row width.
///
/// `selectionAdapter` is `nil` (no glyph hit testing, no copy);
/// `interactiveHits` is empty. The pill is decorative.
struct LoadingPillLayout: @unchecked Sendable {
    let totalHeight: CGFloat
    let measuredWidth: CGFloat
    /// Pill background rect in layout-local coords.
    let pillRect: CGRect
    /// Per-dot positions (top-left corner) in layout-local coords.
    let dotRects: [CGRect]
    /// Label baseline origin (`CTLineDraw`'s textPosition) in
    /// layout-local coords.
    let labelOrigin: CGPoint
    /// Pre-typeset label line for direct `CTLineDraw` at paint time.
    let labelLine: CTLine

    nonisolated static func make() -> LoadingPillLayout {
        let dotSize = BlockStyle.loadingPillDotSize
        let dotGap = BlockStyle.loadingPillDotGap
        let dotsLabelGap = BlockStyle.loadingPillDotsLabelGap
        let hPad = BlockStyle.loadingPillHorizontalPadding
        let vPad = BlockStyle.loadingPillVerticalPadding

        let font = BlockStyle.loadingPillLabelFont
        let attributed = NSAttributedString(
            string: String(localized: "Working"),
            attributes: [
                .font: font,
                .foregroundColor: BlockStyle.loadingPillLabelForeground,
            ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let typeWidth = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let dotsWidth = dotSize * 3 + dotGap * 2
        // Label vs dots vertical: align both to the visual centre.
        let labelHeight = ascent + descent
        let chipHeight = max(dotSize, labelHeight) + vPad * 2
        let chipWidth = hPad + dotsWidth + dotsLabelGap + typeWidth + hPad

        let chipRect = CGRect(x: 0, y: 0, width: chipWidth, height: chipHeight)
        let chipMidY = chipRect.midY

        // Dots row — centred vertically inside the chip, left-aligned
        // with `hPad` from the chip's left edge.
        var dotRects: [CGRect] = []
        dotRects.reserveCapacity(3)
        let dotsY = chipMidY - dotSize / 2
        for i in 0..<3 {
            let x = hPad + CGFloat(i) * (dotSize + dotGap)
            dotRects.append(CGRect(x: x, y: dotsY, width: dotSize, height: dotSize))
        }

        // Label baseline — centred vertically inside the chip. y-down
        // coords: baseline = midY + (ascent - descent) / 2.
        let labelX = hPad + dotsWidth + dotsLabelGap
        let labelBaselineY = chipMidY + (ascent - descent) / 2
        let labelOrigin = CGPoint(x: labelX, y: labelBaselineY)

        return LoadingPillLayout(
            totalHeight: chipHeight,
            measuredWidth: chipWidth,
            pillRect: chipRect,
            dotRects: dotRects,
            labelOrigin: labelOrigin,
            labelLine: line)
    }

    /// Paints the pill background + label. Dots are NOT drawn here —
    /// the cell hosts animated `CAShapeLayer`s for them via
    /// `SubviewPlan.LoadingDots`.
    func draw(in ctx: CGContext, origin: CGPoint) {
        ctx.saveGState()
        let pill = pillRect.offsetBy(dx: origin.x, dy: origin.y)
        let radius = BlockStyle.loadingPillCornerRadius
        let path = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.setFillColor(BlockStyle.loadingPillFillColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        ctx.setStrokeColor(BlockStyle.loadingPillStrokeColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(path)
        ctx.strokePath()

        // Label. `CTLineDraw` paints at the current `textPosition` with
        // the matrix at default y-up. Flip the y axis for one draw,
        // then restore.
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        ctx.saveGState()
        ctx.translateBy(x: origin.x + labelOrigin.x, y: origin.y + labelOrigin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(labelLine, ctx)
        ctx.restoreGState()

        ctx.restoreGState()
    }
}

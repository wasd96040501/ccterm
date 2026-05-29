import AppKit

/// Immutable layout for the trailing "running" indicator. A single
/// SF Symbol `ellipsis` (hosted in an `NSImageView` via the subview plan)
/// carries the three-dot signal; the symbol-effect API drives the per-dot
/// animation so we get the Apple-tuned cadence (and Reduce Motion handling)
/// for free.
///
/// When a turn is producing tokens, a compact `↑in ↓out` usage label is drawn
/// to the right of the dots. The row height is **constant** whether or not the
/// label is present (the symbol is vertically centered in a band tall enough
/// for the label's line), so flipping usage on/off never changes row height —
/// `Transcript2Coordinator.setTurnUsage` repaints the row with a single-row
/// reload and no `noteHeightOfRows`, mirroring the status-update posture.
///
/// `symbolFrame` is in layout-local coords starting at `x = 0`. The cell's
/// `layoutOrigin.x` shifts the row to the centered content band, so the
/// indicator lines up flush with where paragraphs and user bubbles begin.
///
/// `selectionAdapter` is `nil` (no glyph hit testing, no copy);
/// `interactiveHits` is empty. The row is decorative.
struct LoadingPillLayout: Sendable {
    let totalHeight: CGFloat
    let measuredWidth: CGFloat
    /// Cell-local rect the dots `NSImageView` snaps to.
    let symbolFrame: CGRect
    /// Compact `↑in ↓out` usage label, or `nil` when the turn hasn't counted
    /// any tokens yet. Drawn by `draw(in:origin:)`.
    let usageText: String?
    /// Top-left origin (layout-local) for the usage label, in the flipped
    /// cell coordinate space.
    let usageTextOrigin: CGPoint

    nonisolated static func make(usage: TurnTokenUsage = .zero) -> LoadingPillLayout {
        let symbolW = BlockStyle.loadingPillWidth
        let symbolH = BlockStyle.loadingPillHeight
        let font = BlockStyle.loadingPillUsageFont
        // Reserve a band tall enough for the usage line whether or not the
        // label is present, so usage appearing never reflows the row.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let rowH = max(symbolH, lineHeight)
        let symbolFrame = CGRect(
            x: 0, y: (rowH - symbolH) / 2, width: symbolW, height: symbolH)

        let label = usage.compactLabel
        var width = symbolW
        var textOrigin = CGPoint.zero
        if let label {
            let attr = NSAttributedString(
                string: label,
                attributes: [.font: font, .foregroundColor: BlockStyle.loadingPillUsageColor])
            let textW = ceil(attr.size().width)
            let textX = symbolW + BlockStyle.loadingPillUsageGap
            textOrigin = CGPoint(x: textX, y: (rowH - lineHeight) / 2)
            width = textX + textW
        }
        return LoadingPillLayout(
            totalHeight: rowH,
            measuredWidth: width,
            symbolFrame: symbolFrame,
            usageText: label,
            usageTextOrigin: textOrigin)
    }

    /// Paints the usage label (when present). The dots are an `NSImageView`
    /// hosted via the subview plan — nothing to draw for them here.
    func draw(in ctx: CGContext, origin: CGPoint) {
        guard let usageText, !usageText.isEmpty else { return }
        let attr = NSAttributedString(
            string: usageText,
            attributes: [
                .font: BlockStyle.loadingPillUsageFont,
                .foregroundColor: BlockStyle.loadingPillUsageColor,
            ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attr.draw(
            at: CGPoint(
                x: origin.x + usageTextOrigin.x,
                y: origin.y + usageTextOrigin.y))
        NSGraphicsContext.restoreGraphicsState()
    }
}

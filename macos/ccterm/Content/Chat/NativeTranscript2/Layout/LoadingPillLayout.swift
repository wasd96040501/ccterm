import AppKit

/// Immutable layout for the trailing "running" indicator. A single
/// SF Symbol `ellipsis` (hosted in an `NSImageView` via the subview plan)
/// carries the three-dot signal; the symbol-effect API drives the per-dot
/// animation so we get the Apple-tuned cadence (and Reduce Motion handling)
/// for free.
///
/// When a turn is producing tokens, a compact `↑in ↓out` usage label sits to
/// the right of the dots. It is **not** drawn into the cell bitmap — it lives
/// in a dedicated `LoadingPillUsageView` (built from `usageRect` via the
/// subview plan) so the numbers can roll up odometer-style as `setTurnUsage`
/// reloads the pill row each tick. The row height is **constant** whether or
/// not the label is present (the symbol is vertically centered in a band tall
/// enough for the label's line), so flipping usage on/off never changes row
/// height — `Transcript2Coordinator.setTurnUsage` repaints the row with a
/// single-row reload and no `noteHeightOfRows`, mirroring the status-update
/// posture.
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
    /// The raw, cache-excluded turn token totals the usage view renders +
    /// rolls. Carried through to the subview plan.
    let usage: TurnTokenUsage
    /// Layout-local rect (flipped cell coords) the usage view snaps to, or
    /// `nil` when the turn hasn't counted any tokens yet.
    let usageRect: CGRect?

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

        var width = symbolW
        var usageRect: CGRect? = nil
        if let label = usage.compactLabel {
            let attr = NSAttributedString(
                string: label,
                attributes: [.font: font, .foregroundColor: BlockStyle.loadingPillUsageColor])
            // Slack so an in-flight roll toward a wider target never clips.
            let textW = ceil(attr.size().width) + 2
            let textX = symbolW + BlockStyle.loadingPillUsageGap
            usageRect = CGRect(
                x: textX, y: (rowH - lineHeight) / 2, width: textW, height: lineHeight)
            width = textX + textW
        }
        return LoadingPillLayout(
            totalHeight: rowH,
            measuredWidth: width,
            symbolFrame: symbolFrame,
            usage: usage,
            usageRect: usageRect)
    }

    /// Nothing to draw into the cell bitmap — the dots are an `NSImageView`
    /// and the usage counter is a `LoadingPillUsageView`, both hosted via the
    /// subview plan.
    func draw(in ctx: CGContext, origin: CGPoint) {}
}

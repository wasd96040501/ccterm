import AppKit

/// Immutable layout for the trailing "running" indicator. A single
/// SF Symbol `ellipsis` (hosted in an `NSImageView` via the subview plan)
/// carries the three-dot signal; the symbol-effect API drives the per-dot
/// animation so we get the Apple-tuned cadence (and Reduce Motion handling)
/// for free.
///
/// A compact trailing chip sits to the right of the dots: a live elapsed
/// "1d 2h 3m 4s"-style turn clock (whenever `startedAt` is set), and — once the
/// turn has produced tokens — a ` · ↑in ↓out` usage suffix. It is **not** drawn
/// into the cell bitmap; it lives in a dedicated `LoadingPillUsageView` (built
/// from `usageRect` via the subview plan) so the clock self-ticks and the token
/// numbers roll up odometer-style without re-laying out the row. The row height
/// is **constant** whether or not the chip is present (the symbol is vertically
/// centered in a band tall enough for the chip's line), so flipping the chip
/// on/off never changes row height — `Transcript2Coordinator.setTurnUsage` /
/// `setTurnStartedAt` repaint the row with a single-row reload and no
/// `noteHeightOfRows`, mirroring the status-update posture. The hosted view owns
/// its own width (the clock string grows as it ticks), so `usageRect`'s width is
/// only a best-effort reservation for the chip's first frame.
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
    /// Turn start instant — the anchor the elapsed clock counts up from.
    /// Carried through to the subview plan; `nil` → no clock (off-main
    /// precompute paths, or before a turn starts).
    let startedAt: Date?
    /// Layout-local rect (flipped cell coords) the trailing chip snaps to, or
    /// `nil` when there's neither a clock nor any counted tokens to show.
    let usageRect: CGRect?

    nonisolated static func make(
        usage: TurnTokenUsage = .zero, startedAt: Date? = nil
    ) -> LoadingPillLayout {
        let symbolW = BlockStyle.loadingPillWidth
        let symbolH = BlockStyle.loadingPillHeight
        let font = BlockStyle.loadingPillUsageFont
        // Reserve a band tall enough for the chip line whether or not it's
        // present, so the chip appearing never reflows the row.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let rowH = max(symbolH, lineHeight)
        let symbolFrame = CGRect(
            x: 0, y: (rowH - symbolH) / 2, width: symbolW, height: symbolH)

        var width = symbolW
        var usageRect: CGRect? = nil
        // The chip shows whenever there's a clock to run or tokens to display.
        if startedAt != nil || usage.compactLabel != nil {
            // Best-effort width reservation. The hosted view self-sizes to its
            // live content (the clock grows as it ticks), so this only governs
            // the chip's first frame and the row's reported `measuredWidth`.
            var sample = ""
            if startedAt != nil { sample = "00m 00s" }
            if let label = usage.compactLabel {
                sample += (sample.isEmpty ? "" : " · ") + label
            }
            let attr = NSAttributedString(
                string: sample,
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
            startedAt: startedAt,
            usageRect: usageRect)
    }

    /// Nothing to draw into the cell bitmap — the dots are an `NSImageView`
    /// and the usage counter is a `LoadingPillUsageView`, both hosted via the
    /// subview plan.
    func draw(in ctx: CGContext, origin: CGPoint) {}
}

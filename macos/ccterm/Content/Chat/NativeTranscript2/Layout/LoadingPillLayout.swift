import AppKit

/// Immutable layout for the trailing "running" indicator. A single
/// SF Symbol `ellipsis` hosted in an `NSImageView` carries the
/// three-dot signal; the symbol-effect API drives the per-dot
/// animation so we get the Apple-tuned cadence (and Reduce Motion
/// handling) for free instead of hand-rolling keyframes.
///
/// `symbolFrame` is in layout-local coords starting at `x = 0`. The
/// cell's `layoutOrigin.x` shifts the row to the centered content
/// band, so the indicator lines up flush with where paragraphs and
/// user bubbles begin.
///
/// `selectionAdapter` is `nil` (no glyph hit testing, no copy);
/// `interactiveHits` is empty. The row is decorative.
struct LoadingPillLayout: Sendable {
    let totalHeight: CGFloat
    let measuredWidth: CGFloat
    /// Cell-local rect the `NSImageView` snaps to.
    let symbolFrame: CGRect

    nonisolated static func make() -> LoadingPillLayout {
        let w = BlockStyle.loadingPillWidth
        let h = BlockStyle.loadingPillHeight
        return LoadingPillLayout(
            totalHeight: h,
            measuredWidth: w,
            symbolFrame: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// No-op. The indicator paints via the hosted `NSImageView`;
    /// the cell bitmap has nothing to draw for this row.
    func draw(in ctx: CGContext, origin: CGPoint) {}
}

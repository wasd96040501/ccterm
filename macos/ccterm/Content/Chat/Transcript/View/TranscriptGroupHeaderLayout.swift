import AppKit
import CoreText

/// Measure for the transcript's tool-group header rows — a single title
/// line centered in a fixed-height band.
///
/// Lives here, not in `Components/Markdown`, because it isn't a markdown
/// concept: it renders an aggregated narration phrase the transcript
/// builds itself ("Edited 3 files · Searched 1 pattern") and has no
/// `Block.Kind`. It does reuse the component's `TextLayout` primitive and
/// the shared `BlockStyle.toolHeader*` typography, so it reads at the
/// same pitch as the content around it.
struct TranscriptGroupHeaderLayout: @unchecked Sendable {
    /// The typeset title line(s).
    let text: TextLayout
    /// Layout-local y offset that vertically centers the title inside the
    /// fixed header band.
    let textTopInset: CGFloat
    /// Fixed header-band height (`BlockStyle.toolHeaderHeight`).
    let totalHeight: CGFloat

    var measuredWidth: CGFloat { text.measuredWidth }

    nonisolated static func make(
        title: String, maxWidth: CGFloat
    ) -> TranscriptGroupHeaderLayout {
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
        return TranscriptGroupHeaderLayout(
            text: text, textTopInset: inset, totalHeight: height)
    }

    /// Draw the title into a flipped view. `origin` is the layout's
    /// top-left in view coords.
    func draw(in ctx: CGContext, origin: CGPoint) {
        text.draw(
            in: ctx,
            origin: CGPoint(x: origin.x, y: origin.y + textTopInset))
    }
}

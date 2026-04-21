import AppKit
import CoreText

/// Static helpers: turn an `NSAttributedString` into a drawable
/// ``TranscriptTextLayout``, and blit it into a flipped `CGContext`.
///
/// Uses `CTFramesetter` (not `CTTypesetter` directly) so `NSParagraphStyle`
/// attributes—`paragraphSpacing`, `lineSpacing`, head indents, tab stops—that
/// `MarkdownAttributedBuilder` already emits are respected without a
/// re-implementation.
enum TranscriptTextRenderer {

    // MARK: - Layout

    /// Typeset `attributed` within `maxWidth`. Returned layout's
    /// ``TranscriptTextLayout/totalHeight`` fits all lines.
    static func makeLayout(
        attributed: NSAttributedString,
        maxWidth: CGFloat
    ) -> TranscriptTextLayout {
        guard attributed.length > 0, maxWidth > 0 else {
            return TranscriptTextLayout(
                attributed: attributed,
                lines: [],
                lineOrigins: [],
                totalHeight: 0,
                measuredWidth: 0)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil)
        let height = ceil(suggested.height) + 1  // +1 guard against descender clipping

        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: maxWidth, height: height),
            transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil)

        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        guard !ctLines.isEmpty else {
            return TranscriptTextLayout(
                attributed: attributed,
                lines: [],
                lineOrigins: [],
                totalHeight: 0,
                measuredWidth: 0)
        }
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var measuredWidth: CGFloat = 0
        var flippedOrigins: [CGPoint] = []
        flippedOrigins.reserveCapacity(ctLines.count)
        var lowestBaseline: CGFloat = 0  // smallest origin.y seen (used to trim height)
        for (i, line) in ctLines.enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            measuredWidth = max(measuredWidth, w)
            let o = origins[i]
            lowestBaseline = min(lowestBaseline, o.y - descent)
            // Flipped: y increases down. baseline_y = frameHeight - o.y.
            flippedOrigins.append(CGPoint(x: o.x, y: height - o.y))
        }
        let trimmedHeight = ceil(height - max(0, lowestBaseline))

        return TranscriptTextLayout(
            attributed: attributed,
            lines: ctLines,
            lineOrigins: flippedOrigins,
            totalHeight: trimmedHeight,
            measuredWidth: ceil(measuredWidth))
    }

    // MARK: - Draw

    /// Blit a laid-out `layout` into the current flipped `CGContext` at
    /// `origin` (left-top of the layout in the view's flipped coordinates).
    ///
    /// Two passes:
    /// 1. Inline code chip backgrounds (rounded rects drawn per `CTRun` that
    ///    carries `.inlineCodeBackground`)
    /// 2. Glyphs via `CTLineDraw` (text matrix flipped so glyphs render upright)
    static func draw(
        _ layout: TranscriptTextLayout,
        origin: CGPoint,
        inlineCodeChip: InlineCodeChipStyle? = .default,
        in ctx: CGContext
    ) {
        guard !layout.lines.isEmpty else { return }

        // Pass 1: inline code chip backgrounds.
        if let style = inlineCodeChip {
            for (line, p) in zip(layout.lines, layout.lineOrigins) {
                let baseline = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
                drawInlineCodeChips(
                    line: line, baseline: baseline,
                    style: style, in: ctx)
            }
        }

        // Pass 2: glyphs.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (line, p) in zip(layout.lines, layout.lineOrigins) {
            ctx.textPosition = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    struct InlineCodeChipStyle {
        var horizontalPadding: CGFloat
        var cornerRadius: CGFloat

        static let `default` = InlineCodeChipStyle(horizontalPadding: 4, cornerRadius: 3)
    }

    private static func drawInlineCodeChips(
        line: CTLine,
        baseline: CGPoint,
        style: InlineCodeChipStyle,
        in ctx: CGContext
    ) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let color = attrs[NSAttributedString.Key.inlineCodeBackground] as? NSColor else {
                continue
            }
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }

            var firstPos = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &firstPos)

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTRunGetTypographicBounds(
                run,
                CFRange(location: 0, length: 0),
                &ascent, &descent, &leading))

            // Flipped coords: baseline.y is the baseline; chip extends by
            // `ascent` upward (= smaller y) and `descent` downward.
            let chipRect = CGRect(
                x: baseline.x + firstPos.x - style.horizontalPadding,
                y: baseline.y - ascent,
                width: width + 2 * style.horizontalPadding,
                height: ascent + descent)

            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            let path = CGPath(
                roundedRect: chipRect,
                cornerWidth: style.cornerRadius,
                cornerHeight: style.cornerRadius,
                transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}

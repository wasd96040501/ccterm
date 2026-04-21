import AppKit
import CoreText

/// Immutable Core Text layout result: laid-out lines + per-line geometry.
///
/// 建造方式对齐 Telegram `TextViewLayout.calculateLayout`：用 `CTTypesetter`
/// 逐行排版，行高 / 段距全部手算，不依赖 `CTFramesetter` 的 suggested size。
/// - `totalHeight` = 实际各行占用之和，天然不会裁 descender/ascender
/// - `NSParagraphStyle` 的 `lineSpacing` / `paragraphSpacing` / 缩进精确生效
///
/// 坐标约定：所有 y 都是 flipped（y 向下递增，原点在 layout 左上）。
/// - `lineOrigins[i]`：第 i 行的 baseline 相对 layout 顶部的偏移。
struct TranscriptTextLayout {
    let attributed: NSAttributedString
    let lines: [CTLine]
    let lineOrigins: [CGPoint]
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    static let empty = TranscriptTextLayout(
        attributed: NSAttributedString(),
        lines: [],
        lineOrigins: [],
        totalHeight: 0,
        measuredWidth: 0)

    // MARK: - Build

    static func make(
        attributed: NSAttributedString,
        maxWidth: CGFloat
    ) -> TranscriptTextLayout {
        guard attributed.length > 0, maxWidth > 0 else {
            return .empty
        }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = attributed.string as NSString

        var lines: [CTLine] = []
        var lineOrigins: [CGPoint] = []
        var y: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        var start: CFIndex = 0
        let total: CFIndex = attributed.length

        while start < total {
            // 当前段的 paragraph style。MarkdownAttributedBuilder 对每段都贴了
            // 完整 NSParagraphStyle（首行缩进 / 后续行缩进 / 行距 / 段距）。
            let style = (attributed.attribute(
                .paragraphStyle,
                at: start,
                effectiveRange: nil) as? NSParagraphStyle) ?? .default

            let isFirstLineOfParagraph = (start == 0)
                || ns.character(at: start - 1) == 10  // '\n'

            let indent = isFirstLineOfParagraph
                ? style.firstLineHeadIndent
                : style.headIndent
            let avail = max(1, maxWidth - indent)

            // SuggestLineBreak 可能返回 0（异常字符或超宽单 glyph）——强制
            // 至少消费 1 个字符以避免死循环。
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(avail))
            if count <= 0 { count = 1 }

            let line = CTTypesetterCreateLine(
                typesetter,
                CFRange(location: start, length: count))

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let rawWidth = CGFloat(CTLineGetTypographicBounds(
                line, &ascent, &descent, &leading))

            maxLineWidth = max(maxLineWidth, rawWidth + indent)

            let lineHeight = floor(ascent + descent)
            let lineSpacing: CGFloat = style.lineSpacing > 0
                ? style.lineSpacing
                : floor(lineHeight * 0.12)

            if !lineOrigins.isEmpty {
                y += lineSpacing
            }

            lineOrigins.append(CGPoint(x: indent, y: y + ascent))
            y += lineHeight

            lines.append(line)
            start += count

            let endsParagraph = start > 0
                && start <= ns.length
                && ns.character(at: start - 1) == 10
            if endsParagraph, style.paragraphSpacing > 0 {
                y += style.paragraphSpacing
            }
        }

        return TranscriptTextLayout(
            attributed: attributed,
            lines: lines,
            lineOrigins: lineOrigins,
            totalHeight: ceil(y),
            measuredWidth: ceil(maxLineWidth))
    }

    // MARK: - Draw

    struct InlineCodeChipStyle {
        var horizontalPadding: CGFloat
        var cornerRadius: CGFloat

        static let `default` = InlineCodeChipStyle(horizontalPadding: 4, cornerRadius: 3)
    }

    /// 两趟：先绘制 inline code chip 背景，再绘制 glyph。
    func draw(
        origin: CGPoint,
        inlineCodeChip: InlineCodeChipStyle? = .default,
        in ctx: CGContext
    ) {
        guard !lines.isEmpty else { return }

        if let style = inlineCodeChip {
            for (line, p) in zip(lines, lineOrigins) {
                let baseline = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
                Self.drawInlineCodeChips(
                    line: line, baseline: baseline,
                    style: style, in: ctx)
            }
        }

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (line, p) in zip(lines, lineOrigins) {
            ctx.textPosition = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
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

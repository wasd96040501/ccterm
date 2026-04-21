import AppKit
import CoreText

/// 对齐 Telegram `TextViewLayout.calculateLayout` 的做法:用 `CTTypesetter` 逐行
/// 排版,行高/段距全部手算,不依赖 `CTFramesetter` 的 suggested size。
/// 好处:
/// - `totalHeight` = 实际各行占用之和,天然不会裁 descender/ascender
/// - `NSParagraphStyle` 的 `lineSpacing` / `paragraphSpacing` / 缩进精确生效
///   (`CTFramesetter` 只会"尽量"honor,会出现 1-2pt 偏差)
enum TranscriptTextRenderer {

    // MARK: - Layout

    /// 逐行排版 `attributed`(最大宽度 `maxWidth`)。
    static func makeLayout(
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
            // 当前段的 paragraph style。MarkdownAttributedBuilder 对每段都贴了完整
            // NSParagraphStyle(首行缩进 / 后续行缩进 / 行距 / 段距)。
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

            // 找断点。`SuggestLineBreak` 可能返回 0(异常字符或超宽单 glyph)——
            // 强制至少消费 1 个字符避免死循环。
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(avail))
            if count <= 0 { count = 1 }

            let line = CTTypesetterCreateLine(
                typesetter,
                CFRange(location: start, length: count))

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let rawWidth = CGFloat(CTLineGetTypographicBounds(
                line, &ascent, &descent, &leading))

            maxLineWidth = max(maxLineWidth, rawWidth + indent)

            // 行高:遵循 Telegram,使用 floor(ascent + descent)。
            let lineHeight = floor(ascent + descent)
            // 行距:paragraphStyle 有值就用,否则按 12% line height 兜底(Telegram 默认)。
            let lineSpacing: CGFloat = style.lineSpacing > 0
                ? style.lineSpacing
                : floor(lineHeight * 0.12)

            // 非首行:先扣上一行的行距。
            if !lineOrigins.isEmpty {
                y += lineSpacing
            }

            // baseline_y(flipped 坐标,从 layout top 往下)= 当前 y 偏移 + ascent
            lineOrigins.append(CGPoint(x: indent, y: y + ascent))
            y += lineHeight

            lines.append(line)
            start += count

            // 段落结束(以 \n 收尾)→ 吃掉 paragraphSpacing
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

    /// 两趟:先 inline code chip 背景,再 glyph。
    static func draw(
        _ layout: TranscriptTextLayout,
        origin: CGPoint,
        inlineCodeChip: InlineCodeChipStyle? = .default,
        in ctx: CGContext
    ) {
        guard !layout.lines.isEmpty else { return }

        if let style = inlineCodeChip {
            for (line, p) in zip(layout.lines, layout.lineOrigins) {
                let baseline = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
                drawInlineCodeChips(
                    line: line, baseline: baseline,
                    style: style, in: ctx)
            }
        }

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

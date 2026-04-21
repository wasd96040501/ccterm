import AppKit
import CoreText

/// Immutable Core Text layout result: laid-out lines + per-line geometry.
///
/// Build: `CTTypesetter` per-line，行高 / 段距手算，不依赖 `CTFramesetter`。
/// - `totalHeight` = 实际各行占用之和，不裁 ascender/descender
/// - `NSParagraphStyle` 的 `lineSpacing` / `paragraphSpacing` / 缩进精确生效
///
/// 坐标：y 向下递增（flipped），`lineOrigins[i]` 是第 i 行 baseline 相对
/// layout 原点（左上）的偏移。
struct TranscriptTextLayout {
    let attributed: NSAttributedString
    let lines: [CTLine]
    /// 每行 baseline 的 (x, y)，y 是从 layout 顶部往下的距离。
    let lineOrigins: [CGPoint]
    /// 每行在 layout 中的 rect (y = top, height = ascent+descent+可能的 spacing)。
    /// 选中 / 点击命中测试都用它——baseline 不够，需要 rect。
    let lineRects: [CGRect]
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    static let empty = TranscriptTextLayout(
        attributed: NSAttributedString(),
        lines: [],
        lineOrigins: [],
        lineRects: [],
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
        var lineRects: [CGRect] = []
        var y: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        var start: CFIndex = 0
        let total: CFIndex = attributed.length

        while start < total {
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

            let lineTop = y
            lineOrigins.append(CGPoint(x: indent, y: y + ascent))
            y += lineHeight
            lineRects.append(CGRect(
                x: indent,
                y: lineTop,
                width: rawWidth,
                height: lineHeight))

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
            lineRects: lineRects,
            totalHeight: ceil(y),
            measuredWidth: ceil(maxLineWidth))
    }

    // MARK: - Hit-testing / Selection range

    /// `point` 必须已经是 layout 自己的坐标系（左上为原点，y 向下）。
    /// 返回命中的字符 index（或最接近的）；越界返回 nil。
    func characterIndex(at point: CGPoint) -> CFIndex? {
        guard !lines.isEmpty else { return nil }
        let lineIdx = findLineIndex(for: point.y)
        let line = lines[lineIdx]
        let origin = lineOrigins[lineIdx]
        // CTLineGetStringIndexForPosition 的 position.x 是相对 line origin 的；
        // y 忽略。
        let local = CGPoint(x: point.x - origin.x, y: 0)
        let idx = CTLineGetStringIndexForPosition(line, local)
        return idx
    }

    /// 起止两点（layout 坐标系）→ 选中 range。对齐 Telegram
    /// `TextViewLayout.selectedRange(startPoint:currentPoint:)`：
    /// 遍历所在行之间的每行，头尾行按点切、中间行整行纳入；
    /// 自动处理反向（end 在 start 之前）。
    func selectionRange(from startPoint: CGPoint, to endPoint: CGPoint) -> NSRange {
        guard !lines.isEmpty else { return NSRange(location: NSNotFound, length: 0) }

        let startLineIdx = findLineIndex(for: startPoint.y)
        let endLineIdx = findLineIndex(for: endPoint.y)
        let reversed = endLineIdx < startLineIdx
        let lo = min(startLineIdx, endLineIdx)
        let hi = max(startLineIdx, endLineIdx)

        var resultLocation: Int = .max
        var resultLength: Int = 0

        for i in lo...hi {
            let line = lines[i]
            let origin = lineOrigins[i]
            let range = CTLineGetStringRange(line)
            let lineLoc = range.location
            let lineEnd = range.location + range.length

            var startIdx: CFIndex
            var endIdx: CFIndex

            if i == startLineIdx && i == endLineIdx {
                // 同一行：两点在同一行内。
                let sp = CGPoint(x: startPoint.x - origin.x, y: 0)
                let cp = CGPoint(x: endPoint.x - origin.x, y: 0)
                startIdx = CTLineGetStringIndexForPosition(line, sp)
                endIdx = CTLineGetStringIndexForPosition(line, cp)
            } else if i == startLineIdx {
                let sp = CGPoint(x: startPoint.x - origin.x, y: 0)
                startIdx = CTLineGetStringIndexForPosition(line, sp)
                endIdx = reversed ? lineLoc : lineEnd
            } else if i == endLineIdx {
                let cp = CGPoint(x: endPoint.x - origin.x, y: 0)
                endIdx = CTLineGetStringIndexForPosition(line, cp)
                startIdx = reversed ? lineEnd : lineLoc
            } else {
                startIdx = lineLoc
                endIdx = lineEnd
            }

            if startIdx > endIdx {
                swap(&startIdx, &endIdx)
            }
            if endIdx > startIdx {
                resultLocation = min(resultLocation, Int(startIdx))
                resultLength += Int(endIdx - startIdx)
            }
        }

        guard resultLocation != .max, resultLength > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        // clamp 到 attributed 长度
        let totalLen = attributed.length
        let loc = max(0, min(resultLocation, totalLen))
        let len = max(0, min(resultLength, totalLen - loc))
        return NSRange(location: loc, length: len)
    }

    /// y 坐标 → 命中的行下标。超出上/下端分别 clamp 到第一/最后一行。
    private func findLineIndex(for y: CGFloat) -> Int {
        if y <= lineRects.first?.minY ?? 0 { return 0 }
        if y >= lineRects.last?.maxY ?? 0 { return lines.count - 1 }
        for (i, rect) in lineRects.enumerated() {
            if y >= rect.minY && y < rect.maxY { return i }
        }
        return lines.count - 1
    }

    /// 给定 `range`，返回它在每条行内对应的高亮矩形（layout 坐标系）。
    /// 画选中底色时用。跨行自动切段。
    func selectionRects(for range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound, range.length > 0, !lines.isEmpty else {
            return []
        }
        let rangeEnd = range.location + range.length
        var rects: [CGRect] = []
        for (i, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let lineLoc = Int(lineRange.location)
            let lineEnd = lineLoc + Int(lineRange.length)
            let intersectLoc = max(lineLoc, range.location)
            let intersectEnd = min(lineEnd, rangeEnd)
            guard intersectEnd > intersectLoc else { continue }

            let startX = CTLineGetOffsetForStringIndex(line, CFIndex(intersectLoc), nil)
            let endX = CTLineGetOffsetForStringIndex(line, CFIndex(intersectEnd), nil)
            let lineRect = lineRects[i]
            let origin = lineOrigins[i]
            rects.append(CGRect(
                x: origin.x + startX,
                y: lineRect.minY,
                width: max(0, endX - startX),
                height: lineRect.height))
        }
        return rects
    }

    // MARK: - Draw

    struct InlineCodeChipStyle {
        var horizontalPadding: CGFloat
        var cornerRadius: CGFloat

        static let `default` = InlineCodeChipStyle(horizontalPadding: 4, cornerRadius: 3)
    }

    /// 三趟：选中底色（如果有）→ inline code chip → glyph。
    func draw(
        origin: CGPoint,
        selection: NSRange? = nil,
        inlineCodeChip: InlineCodeChipStyle? = .default,
        in ctx: CGContext
    ) {
        guard !lines.isEmpty else { return }

        if let selection {
            ctx.saveGState()
            ctx.setFillColor(Self.selectionHighlightColor().cgColor)
            for rect in selectionRects(for: selection) {
                ctx.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            ctx.restoreGState()
        }

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

    private static func selectionHighlightColor() -> NSColor {
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
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

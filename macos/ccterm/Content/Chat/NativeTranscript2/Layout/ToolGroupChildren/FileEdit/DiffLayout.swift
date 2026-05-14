import AppKit
import CoreText
import SwiftUI

/// Immutable hunks body — the rounded `codeBlock`-style card that
/// appears below an expanded `ToolGroupBlock.Item`. Standalone, not a
/// `RowLayout` case: `ToolGroupLayout` calls `make(...)` to position
/// the card at a given `(x, y)` and `draw(...)` to paint it.
///
/// Body content is a flat list of `Row` values, one per diff line
/// plus inter-hunk ` ··· ` separators. Each row carries its line
/// background + gutter background + pre-typeset `CTLine`, so the
/// draw loop is just two fill passes + one glyph pass.
///
/// ### Async syntax highlighting
///
/// `lineMap == nil` is the cold-render path: every line falls back to
/// `labelColor`. Once `Transcript2HighlightStorage` finishes its
/// per-unique-line `highlightBatch` pass and writes a per-item
/// `.lineMap` value into the storage, the next `make(...)` call reads
/// the map and emits colored attributed strings. Line metrics are
/// unchanged by the swap (same font, same width), so the `onDidFill`
/// reload path does no `noteHeightOfRows`.
///
/// ### New-file mode
///
/// `diff.isNewFile == true` (the prior file didn't exist) demotes
/// every `.add` line to `.context` at the draw stage — same gutter
/// content, no green `+`, no insertion background. The body reads as a
/// viewable copy of the new file rather than a sea of green.
///
/// ### Selection
///
/// Selection is restricted to the **content column** — gutter
/// (line-number) and sign (`+ / - / space`) glyphs are not part of
/// the selectable text. `hitTest` clamps points in those columns to
/// the start of the row's content. The string output joins per-row
/// content with `\n` so paste targets see plain code without the
/// diff chrome columns. Position type is `LayoutPosition.diff(...)`;
/// `ToolGroupLayout` is the one that turns these positions into a
/// `SelectionAdapter`, threading `childIndex` through.
///
/// `@unchecked Sendable`: holds `CTLine` references (same posture as
/// `TextLayout`).
struct DiffLayout: @unchecked Sendable {
    /// Rounded `codeBlock`-style card rect in layout-local coords.
    let containerRect: CGRect

    /// One drawn row inside the card.
    struct Row: @unchecked Sendable {
        /// Full-width line background rect.
        let lineRect: CGRect
        /// Gutter (line-number column) background rect, painted over
        /// `lineRect`'s portion of the same band.
        let gutterRect: CGRect
        let lineBg: NSColor
        let gutterBg: NSColor
        /// Pre-typeset row content (gutter + sign + content, or
        /// ` ··· ` for separators). `nil` for empty-content rows.
        let line: CTLine?
        /// Baseline in layout-local coords for `CTLine.draw`.
        let baseline: CGPoint
        /// `true` for content rows (selectable); `false` for inter-
        /// hunk `···` separators (decorative).
        let isContent: Bool
        /// UTF-16 offset where the *content* column starts inside
        /// `line`'s attributed string. `0` for separator rows.
        let contentStartIndex: Int
        /// UTF-16 length of the content text itself (excludes prefix
        /// gutter / sign / trailing space). `0` for separators or
        /// empty-content lines.
        let contentLength: Int
        /// Raw content text — used by `string(loChar:hiChar:)` so
        /// pasteboard output stays clean even when the rendered
        /// attributed string contains token-coloured sub-runs.
        let contentText: String
        /// Cumulative content-only character count from the body's
        /// start up to (but not including) this row, in the joined
        /// `"row1\nrow2\nrow3"` text. Separator rows carry `0` and
        /// do not advance the counter.
        let globalStart: Int
    }

    let rows: [Row]

    /// Total length of the joined body text (`row.contentText`
    /// values separated by `\n`). Equal to
    /// `sum(contentLength) + (numberOfContentRows - 1)` for ≥ 1
    /// content row, `0` otherwise.
    let contentLength: Int

    /// Height of the whole card. Reported up to `ToolGroupLayout` for
    /// total-row-height accounting.
    var totalHeight: CGFloat { containerRect.height }

    // MARK: - Factory

    /// Layout the card with its top-left corner at `(originX, originY)`.
    /// `maxWidth` is the available card width; the gutter / sign /
    /// content columns size themselves inside it.
    nonisolated static func make(
        diff: DiffBlock,
        lineMap: [String: [SyntaxToken]]?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> DiffLayout {
        guard maxWidth > 0 else {
            return DiffLayout(containerRect: .zero, rows: [], contentLength: 0)
        }

        let suppressAdd = diff.isNewFile
        let hunks = DiffEngine.computeHunks(
            old: diff.effectiveOldString, new: diff.newString)
        guard !hunks.isEmpty else {
            return DiffLayout(containerRect: .zero, rows: [], contentLength: 0)
        }

        let font = BlockStyle.diffBodyFont
        let lineH = font.ascender - font.descender

        // Gutter width: padded to the widest line number across all
        // hunks plus a space on each side.
        let maxLineNo = hunks.flatMap(\.lines).compactMap(\.lineNo).max() ?? 0
        let digits = max(2, String(maxLineNo).count)
        let gutterText = String(repeating: " ", count: digits + 2) // " NNN "
        let gutterWidth = textWidth(gutterText, attrs: [.font: font])

        // Per-row prefix length is constant within a body: " NNN " +
        // " ± " = (digits + 2) + 3 = digits + 5 UTF-16 units.
        let prefixUTF16: Int = (digits + 2) + 3

        var rows: [Row] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
        let innerPad = BlockStyle.diffInnerVerticalPadding
        var y: CGFloat = originY + innerPad
        var runningContentChars = 0
        var hasEmittedContent = false

        for (hi, hunk) in hunks.enumerated() {
            if hi > 0 {
                let sepRect = CGRect(x: originX, y: y,
                                     width: maxWidth, height: lineH)
                let sepLine = CTLineCreateWithAttributedString(
                    NSAttributedString(string: " ··· ", attributes: [
                        .font: font,
                        .foregroundColor: BlockStyle.diffSeparatorForeground,
                    ]))
                rows.append(Row(
                    lineRect: sepRect,
                    gutterRect: .zero,
                    lineBg: BlockStyle.diffSeparatorBackground,
                    gutterBg: .clear,
                    line: sepLine,
                    baseline: CGPoint(
                        x: originX + BlockStyle.bubbleHorizontalPadding,
                        y: y + font.ascender),
                    isContent: false,
                    contentStartIndex: 0,
                    contentLength: 0,
                    contentText: "",
                    globalStart: 0))
                y += lineH
            }
            for line in hunk.lines {
                let effectiveType: DiffEngine.Line.LineType =
                    (suppressAdd && line.type == .add) ? .context : line.type
                let lineRect = CGRect(x: originX, y: y,
                                      width: maxWidth, height: lineH)
                let gutterRect = CGRect(
                    x: originX, y: y, width: gutterWidth, height: lineH)
                let attr = buildLineAttributed(
                    line: line, effectiveType: effectiveType,
                    digits: digits, font: font,
                    tokens: lineMap?[line.content])
                let ctLine = CTLineCreateWithAttributedString(attr)
                let contentLenU16 = (line.content as NSString).length
                // Each preceding content row contributes its content
                // length + 1 (newline). The first row starts at 0.
                let globalStart = hasEmittedContent
                    ? (runningContentChars + 1)
                    : 0
                rows.append(Row(
                    lineRect: lineRect,
                    gutterRect: gutterRect,
                    lineBg: DiffColors.dynamicContentBg(effectiveType),
                    gutterBg: DiffColors.dynamicGutterBg(effectiveType),
                    line: ctLine,
                    baseline: CGPoint(x: originX, y: y + font.ascender),
                    isContent: true,
                    contentStartIndex: prefixUTF16,
                    contentLength: contentLenU16,
                    contentText: line.content,
                    globalStart: globalStart))
                runningContentChars = globalStart + contentLenU16
                hasEmittedContent = true
                y += lineH
            }
        }

        // Extend the first row's line/gutter fill up to the card's top
        // edge and the last row's down to the bottom edge so the add/
        // del tint runs flush against the card corners — only the
        // glyph baseline sits inside the `innerPad` band, the colour
        // band does not.
        if !rows.isEmpty {
            rows[0] = expandTopFill(rows[0], by: innerPad)
            let lastIdx = rows.count - 1
            rows[lastIdx] = expandBottomFill(rows[lastIdx], by: innerPad)
        }

        let containerHeight = (y + innerPad) - originY
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: containerHeight)
        return DiffLayout(
            containerRect: container,
            rows: rows,
            contentLength: runningContentChars)
    }

    nonisolated private static func expandTopFill(_ row: Row, by pad: CGFloat) -> Row {
        Row(
            lineRect: CGRect(
                x: row.lineRect.minX, y: row.lineRect.minY - pad,
                width: row.lineRect.width,
                height: row.lineRect.height + pad),
            gutterRect: row.gutterRect.isEmpty ? .zero : CGRect(
                x: row.gutterRect.minX, y: row.gutterRect.minY - pad,
                width: row.gutterRect.width,
                height: row.gutterRect.height + pad),
            lineBg: row.lineBg, gutterBg: row.gutterBg,
            line: row.line, baseline: row.baseline,
            isContent: row.isContent,
            contentStartIndex: row.contentStartIndex,
            contentLength: row.contentLength,
            contentText: row.contentText,
            globalStart: row.globalStart)
    }

    nonisolated private static func expandBottomFill(_ row: Row, by pad: CGFloat) -> Row {
        Row(
            lineRect: CGRect(
                x: row.lineRect.minX, y: row.lineRect.minY,
                width: row.lineRect.width,
                height: row.lineRect.height + pad),
            gutterRect: row.gutterRect.isEmpty ? .zero : CGRect(
                x: row.gutterRect.minX, y: row.gutterRect.minY,
                width: row.gutterRect.width,
                height: row.gutterRect.height + pad),
            lineBg: row.lineBg, gutterBg: row.gutterBg,
            line: row.line, baseline: row.baseline,
            isContent: row.isContent,
            contentStartIndex: row.contentStartIndex,
            contentLength: row.contentLength,
            contentText: row.contentText,
            globalStart: row.globalStart)
    }

    nonisolated private static func textWidth(
        _ s: String, attrs: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    /// Per-line attributed string: ` NNN ` (gutter) + ` ± ` (sign) +
    /// `content`. Tokens from `lineMap` colourise the `content` segment;
    /// absent / `nil` falls back to `labelColor`. Gutter and sign live
    /// outside `lineMap` so they always render even on the cold path.
    nonisolated private static func buildLineAttributed(
        line: DiffEngine.Line,
        effectiveType: DiffEngine.Line.LineType,
        digits: Int,
        font: NSFont,
        tokens: [SyntaxToken]?
    ) -> NSAttributedString {
        let lineNoStr = line.lineNo.map(String.init) ?? ""
        let padded = String(repeating: " ", count: max(0, digits - lineNoStr.count))
            + lineNoStr

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: " \(padded) ", attributes: [
            .font: font,
            .foregroundColor: BlockStyle.diffGutterForeground,
        ]))

        let sign: String
        let signColor: NSColor
        switch effectiveType {
        case .add:     sign = "+"; signColor = BlockStyle.diffSignAddForeground
        case .del:     sign = "-"; signColor = BlockStyle.diffSignDelForeground
        case .context: sign = " "; signColor = NSColor.labelColor
        }
        result.append(NSAttributedString(string: " \(sign) ", attributes: [
            .font: font,
            .foregroundColor: signColor,
        ]))

        if let tokens, !line.content.isEmpty {
            for token in tokens {
                let color = colorForToken(scope: token.scope)
                result.append(NSAttributedString(string: token.text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ]))
            }
        } else if !line.content.isEmpty {
            result.append(NSAttributedString(string: line.content, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]))
        }

        result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        return result
    }

    nonisolated private static func colorForToken(scope: String?) -> NSColor {
        NSColor(name: nil) { appearance in
            let scheme: SwiftUI.ColorScheme =
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .dark : .light
            return NSColor(SyntaxTheme.color(for: scope, scheme: scheme))
        }
    }

    // MARK: - Selection helpers
    //
    // Positions are layout-local UTF-16 offsets into the joined body
    // text (`row.contentText` values separated by `\n`). Gutter and
    // sign columns are *not* selectable — `hitTest` clamps point.x
    // outside the content column to the row's nearest content edge.

    /// Map a layout-local point to a content-only char offset.
    /// Out-of-band points clamp:
    /// - `y` above the first content row → `0`
    /// - `y` below the last content row  → `contentLength`
    /// - `x` left of the content column  → start of the row's content
    /// - `x` right of the content column → end of the row's content
    func hitTest(point: CGPoint) -> Int {
        guard contentLength > 0 else { return 0 }

        // Walk rows top-down. Skip separators. Track the most recent
        // content row whose top has been crossed; clamp to its end if
        // the point falls in a gap or below the last row.
        var lastContentRow: Row?
        for row in rows where row.isContent {
            if point.y < row.lineRect.minY {
                // Above this row. If a previous content row exists,
                // clamp to its end; else clamp to the first row's
                // start.
                if let prev = lastContentRow {
                    return prev.globalStart + prev.contentLength
                }
                return row.globalStart
            }
            if point.y <= row.lineRect.maxY {
                return Self.charIndex(in: row, atLocalX: point.x)
            }
            lastContentRow = row
        }
        // Past the last content row.
        if let last = lastContentRow {
            return last.globalStart + last.contentLength
        }
        return 0
    }

    /// Selection rects covering the half-open range `[loChar, hiChar)`.
    /// One rect per content row whose body chars intersect the range,
    /// tight to the row's full `lineRect` band (so the rect matches
    /// the diff's line-height visual rhythm).
    ///
    /// Content rows don't wrap; a long line's CTLine can resolve a char
    /// `x` past `containerRect.maxX`. The cell paints these rects with
    /// `wantsDefaultClipping = false`, so an unclamped rect spills past
    /// the rounded card edge and gets drawn squarely over the corner.
    /// Clamp each rect's horizontal span into the container so the
    /// selection band stops at the visual card boundary.
    func rects(loChar: Int, hiChar: Int) -> [CGRect] {
        guard loChar < hiChar else { return [] }
        let containerMinX = containerRect.minX
        let containerMaxX = containerRect.maxX
        var out: [CGRect] = []
        for row in rows where row.isContent {
            let rowStart = row.globalStart
            let rowEnd = row.globalStart + row.contentLength
            let lo = max(loChar, rowStart)
            let hi = min(hiChar, rowEnd)
            guard hi >= lo else { continue }
            guard let line = row.line else { continue }
            // Both endpoints empty (e.g. selection lands on the
            // \n separator only) → skip.
            if hi == lo && lo == rowStart { continue }
            let localLo = lo - rowStart
            let localHi = hi - rowStart
            let charLo = row.contentStartIndex + localLo
            let charHi = row.contentStartIndex + localHi
            let xLo = CGFloat(CTLineGetOffsetForStringIndex(line, charLo, nil))
            let xHi = CGFloat(CTLineGetOffsetForStringIndex(line, charHi, nil))
            let baseX = row.lineRect.minX
            let rawLo = baseX + xLo
            let rawHi = baseX + xHi
            let clampedLo = max(containerMinX, min(rawLo, containerMaxX))
            let clampedHi = max(containerMinX, min(rawHi, containerMaxX))
            guard clampedHi > clampedLo else { continue }
            out.append(CGRect(
                x: clampedLo,
                y: row.lineRect.minY,
                width: clampedHi - clampedLo,
                height: row.lineRect.height))
        }
        return out
    }

    /// Plain-text representation of the selection. Joins per-row
    /// `contentText` slices with `\n`. Gutter and sign glyphs are
    /// never included.
    func string(loChar: Int, hiChar: Int) -> String {
        guard loChar < hiChar else { return "" }
        var out = ""
        var first = true
        for row in rows where row.isContent {
            let rowStart = row.globalStart
            let rowEnd = row.globalStart + row.contentLength
            // We always emit a row's contribution (possibly empty)
            // when the range covers any part of the row OR a
            // newline boundary just after it. Easier formulation:
            // include this row if `loChar <= rowEnd && hiChar > rowStart`,
            // OR the trailing `\n` (i.e., rowEnd) is inside the range.
            let nlIndex = rowEnd
            let trailingNlInRange = (nlIndex >= loChar && nlIndex < hiChar)
            let bodyOverlap = (hiChar > rowStart && loChar < rowEnd) ||
                              (rowStart == rowEnd && loChar <= rowStart && rowStart < hiChar)
            guard bodyOverlap || trailingNlInRange else { continue }
            let lo = max(loChar, rowStart)
            let hi = min(hiChar, rowEnd)
            let localLo = lo - rowStart
            let localHi = max(0, hi - rowStart)
            let nsText = row.contentText as NSString
            let slice = (localHi > localLo)
                ? nsText.substring(with: NSRange(location: localLo,
                                                  length: localHi - localLo))
                : ""
            if !first { out += "\n" }
            out += slice
            first = false
        }
        return out
    }

    /// Word-boundary range around `char` (for double-click selection).
    /// `nil` when the position has no word context (separator-only
    /// rows / empty body).
    func wordBoundary(at char: Int) -> NSRange? {
        for row in rows where row.isContent {
            let rowStart = row.globalStart
            let rowEnd = row.globalStart + row.contentLength
            guard char >= rowStart, char <= rowEnd else { continue }
            guard row.contentLength > 0 else { return nil }
            let local = max(0, min(char - rowStart, row.contentLength - 1))
            // NSString.doubleClick(at:) requires a valid char index
            // strictly inside the string; clamp into [0, len-1].
            let attr = NSAttributedString(string: row.contentText)
            let word = attr.doubleClick(at: local)
            return NSRange(
                location: rowStart + word.location,
                length: word.length)
        }
        return nil
    }

    /// Helper: row-local x → full-line char index, then narrow to the
    /// row's content column (gutter / sign clamps to the row's content
    /// start; trailing space past content clamps to its end).
    nonisolated private static func charIndex(in row: Row, atLocalX x: CGFloat) -> Int {
        guard let line = row.line else { return row.globalStart }
        let baseX = row.lineRect.minX
        let lineLocalX = x - baseX
        let raw = CTLineGetStringIndexForPosition(
            line, CGPoint(x: lineLocalX, y: 0))
        if raw == kCFNotFound {
            return row.globalStart + (lineLocalX < 0 ? 0 : row.contentLength)
        }
        let contentStart = row.contentStartIndex
        let contentEnd = contentStart + row.contentLength
        let clamped = max(contentStart, min(contentEnd, raw))
        return row.globalStart + (clamped - contentStart)
    }

    // MARK: - Draw
    //
    // Split into two passes so `BlockCellView` can sandwich the
    // selection band between them — same recipe as `CodeBlockLayout`:
    //
    //   1. `drawBackplate` — container fill + per-line add/del/gutter
    //      tints. All opaque chrome that must sit *under* selection.
    //   2. selection rects (cell-driven, via `selectionAdapter`).
    //   3. `draw` — glyphs only. Painted on top of the selection band
    //      so anti-aliased text composites correctly, matching
    //      `NSTextView` ordering.
    //
    // Putting line/gutter tints in `draw` would re-cover the selection
    // band drawn by the cell — selection would be visible only where
    // it spilled past the gutter and across an unhighlighted ` `
    // context row.

    /// Container fill + add/del row tint + gutter tint. Painted by
    /// `BlockCellView` before the selection band. All passes clipped to
    /// the rounded card so long lines / extended top+bottom fills don't
    /// bleed past the corners.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        guard !containerRect.isEmpty else { return }
        let containerAtScreen = containerRect.offsetBy(dx: origin.x, dy: origin.y)
        let path = CGPath(
            roundedRect: containerAtScreen,
            cornerWidth: BlockStyle.structuralCornerRadius,
            cornerHeight: BlockStyle.structuralCornerRadius,
            transform: nil)
        ctx.saveGState()
        ctx.setFillColor(BlockStyle.diffContainerBackground.cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.clip()
        // Pass 1 — line backgrounds (full width).
        for row in rows where row.lineBg.alphaComponent > 0 {
            ctx.setFillColor(row.lineBg.cgColor)
            ctx.fill(row.lineRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        // Pass 2 — gutter backgrounds layered over line backgrounds.
        for row in rows where row.gutterBg.alphaComponent > 0 {
            ctx.setFillColor(row.gutterBg.cgColor)
            ctx.fill(row.gutterRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        ctx.restoreGState()
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        guard !containerRect.isEmpty else { return }
        // Clip glyphs to the rounded card so long lines don't bleed
        // past the corners.
        ctx.saveGState()
        let containerAtScreen = containerRect.offsetBy(dx: origin.x, dy: origin.y)
        let clipPath = CGPath(
            roundedRect: containerAtScreen,
            cornerWidth: BlockStyle.structuralCornerRadius,
            cornerHeight: BlockStyle.structuralCornerRadius,
            transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in rows {
            guard let line = row.line else { continue }
            ctx.textPosition = CGPoint(
                x: origin.x + row.baseline.x,
                y: origin.y + row.baseline.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}

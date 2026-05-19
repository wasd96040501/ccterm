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
/// background + gutter background + a pre-typeset prefix (gutter +
/// sign glyphs) + a wrapped content `TextLayout`, so the draw loop
/// is just two fill passes + glyph passes.
///
/// ### Soft wrap
///
/// Long diff lines wrap inside the card. The prefix column glyphs
/// (gutter line number + sign) are painted once on the first visual
/// line; the content `TextLayout` typesets through
/// `CTTypesetterSuggestLineBreak` at `cardWidth - prefixWidth`, so
/// continuation visual lines start at the content column. Add / del
/// line backgrounds and the gutter tint both extend over the full
/// wrapped row band — wrap continuation lines drop the line number
/// glyph but keep the same gutter colour as the first visual line,
/// so the colour column reads as one consistent band.
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
/// content, no green `+`, no insertion background — and drops the
/// sign column from the prefix sizing so the content column reclaims
/// the 3-glyph width that would otherwise sit empty. The body reads
/// as a viewable copy of the new file rather than a sea of green.
/// `ReadChildLayout` reuses this mode to surface the file body the
/// CLI returns from a `Read` tool call.
///
/// ### Selection
///
/// Selection is restricted to the **content column** — gutter
/// (line-number) and sign (`+ / - / space`) glyphs are not part of
/// the selectable text. `hitTest` clamps points in the prefix column
/// to the start of the row's content. The string output joins per-row
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
    /// Stable id for the copy button, used by the cell to key per-
    /// button hover state and post-click checkmark feedback. Equals
    /// the owning child's UUID so the same id keys other per-child
    /// state on the cell side.
    let copyButtonId: UUID
    /// Hit zone for the copy button, in layout-local coords. **Overlay
    /// rect** — sits in the top-right corner of the card without
    /// occupying row space; rows underneath continue to flow as if
    /// the button weren't there. `nil` when the container is too
    /// narrow to host the button without spilling past its corner, or
    /// when `rows` is empty.
    let copyHitRect: CGRect?
    /// Glyph center for the copy SF Symbol. `nil` when `copyHitRect`
    /// is also nil.
    let copyCenter: CGPoint?
    /// Payload copied to the pasteboard when the button is clicked.
    /// Post-edit content for FileEdit, file body for Read. Captured
    /// at make time so the cell's click handler doesn't have to
    /// re-derive it.
    let copyText: String
    /// Language badge pill rect, in layout-local coords. **Overlay
    /// rect**, same posture as `copyHitRect`. `nil` when the
    /// language couldn't be inferred, the card is too narrow to host
    /// the badge alongside the copy button, or `rows` is empty.
    let langBadgeRect: CGRect?
    /// Badge text (highlight.js language name, lowercased). `nil`
    /// when no language was detected.
    let langText: String?

    /// One drawn row inside the card. After soft-wrap, a row spans
    /// `lineRect.height` worth of vertical space — one or more visual
    /// lines stacked from the row's top.
    struct Row: @unchecked Sendable {
        /// Full-width line band rect spanning all visual lines of the
        /// row (after wrap). Background fill for add / del rows
        /// covers this entire rect.
        let lineRect: CGRect
        /// Gutter (line-number column) background rect — spans the
        /// full wrapped row band so the gutter colour matches across
        /// the first visual line and any continuation lines (the
        /// number glyph is still drawn on the first visual line only,
        /// but the colour column stays consistent). `.zero` for
        /// separator rows.
        let gutterRect: CGRect
        let lineBg: NSColor
        let gutterBg: NSColor
        /// Prefix glyphs: gutter line number + sign column. Painted on
        /// the first visual line only; `nil` for separator rows.
        let prefixLine: CTLine?
        /// Baseline (layout-local coords) for `prefixLine` — aligned
        /// with the first visual line's baseline so prefix and content
        /// share one cap-height row.
        let prefixBaseline: CGPoint
        /// Wrapped content layout. For content rows, this is the
        /// per-diff-line source text — typeset at
        /// `cardWidth - prefixWidth`, may break into multiple visual
        /// lines. For separator rows, this is the centred " ··· "
        /// rendered as a single non-wrapping line.
        let contentLayout: TextLayout
        /// Top-left (layout-local coords) for `contentLayout.draw(...)`
        /// — equal to `lineRect.minX + prefixWidth` for content rows
        /// (so wrap continuation visual lines align with the content
        /// column), and `lineRect.minX + bubbleHorizontalPadding` for
        /// separator rows.
        let contentOrigin: CGPoint
        /// `true` for content rows (selectable); `false` for inter-
        /// hunk `···` separators (decorative).
        let isContent: Bool
        /// UTF-16 length of the content text itself. `0` for
        /// separators or empty-content lines.
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
        copyButtonId: UUID,
        copyText: String,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> DiffLayout {
        guard maxWidth > 0 else {
            return Self.empty(copyButtonId: copyButtonId, copyText: copyText)
        }

        let suppressAdd = diff.isNewFile
        // New-file mode never emits a `+`/`-` glyph (every line is
        // demoted to `.context`), so reserving the 3-char sign column
        // would print a permanently-blank gutter strip. Drop it; the
        // content column reclaims the width and wraps tighter.
        let suppressSign = diff.isNewFile
        let hunks = DiffEngine.computeHunks(
            old: diff.effectiveOldString, new: diff.newString)
        guard !hunks.isEmpty else {
            return Self.empty(copyButtonId: copyButtonId, copyText: copyText)
        }

        let font = BlockStyle.diffBodyFont
        let lineH = font.ascender - font.descender

        // Gutter + sign prefix sizing. Both columns are constant-width
        // within a body — gutter padded to the widest line number, sign
        // is always " ± " in diff mode. `prefixWidth` is what we
        // subtract from `maxWidth` to size the content column, so wrap
        // continuation lines align with the content column.
        let maxLineNo = hunks.flatMap(\.lines).compactMap(\.lineNo).max() ?? 0
        let digits = max(2, String(maxLineNo).count)
        let gutterText = String(repeating: " ", count: digits + 2)  // " NNN "
        let gutterWidth = textWidth(gutterText, attrs: [.font: font])
        // Sign column is 3 mono-glyphs (" + " / " - " / "   ") in diff
        // mode. In new-file mode there's no `+`/`-` glyph to show, but
        // we keep one glyph of width so the content doesn't butt up
        // against the gutter — a single space matches the gutter's own
        // internal padding and reads as a comfortable column gap.
        let signWidth =
            suppressSign
            ? textWidth(" ", attrs: [.font: font])
            : textWidth("   ", attrs: [.font: font])
        let prefixWidth = gutterWidth + signWidth

        // Content column width — the wrap budget for each row's
        // `TextLayout`. Floor at 1 so we never pass a non-positive
        // width to the typesetter.
        let contentMaxWidth = max(1, maxWidth - prefixWidth)

        var rows: [Row] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
        let innerPad = BlockStyle.diffInnerVerticalPadding
        var y: CGFloat = originY + innerPad
        var runningContentChars = 0
        var hasEmittedContent = false

        for (hi, hunk) in hunks.enumerated() {
            if hi > 0 {
                let sepAttr = NSAttributedString(
                    string: " ··· ",
                    attributes: [
                        .font: font,
                        .foregroundColor: BlockStyle.diffSeparatorForeground,
                    ])
                // Separator is short — typeset at full card width so
                // it never wraps even on pathologically narrow cards.
                let sepLayout = TextLayout.make(
                    attributed: sepAttr, maxWidth: maxWidth)
                let sepH = max(lineH, sepLayout.totalHeight)
                let sepRect = CGRect(
                    x: originX, y: y, width: maxWidth, height: sepH)
                rows.append(
                    Row(
                        lineRect: sepRect,
                        gutterRect: .zero,
                        lineBg: BlockStyle.diffSeparatorBackground,
                        gutterBg: .clear,
                        prefixLine: nil,
                        prefixBaseline: .zero,
                        contentLayout: sepLayout,
                        contentOrigin: CGPoint(
                            x: originX + BlockStyle.bubbleHorizontalPadding,
                            y: y),
                        isContent: false,
                        contentLength: 0,
                        contentText: "",
                        globalStart: 0))
                y += sepH
            }
            for line in hunk.lines {
                let effectiveType: DiffEngine.Line.LineType =
                    (suppressAdd && line.type == .add) ? .context : line.type

                // Prefix glyphs: gutter " NNN " + sign " ± " (or just
                // " NNN " in new-file mode). Built as one CTLine so the
                // per-row draw cost stays at one glyph pass instead of two.
                let prefixAttr = buildPrefixAttributed(
                    line: line, effectiveType: effectiveType,
                    digits: digits, font: font,
                    suppressSign: suppressSign)
                let prefixLine = CTLineCreateWithAttributedString(prefixAttr)

                // Content TextLayout — wraps when the source line is
                // wider than the content column. Empty content rows
                // (a blank diff line) produce an empty layout with
                // `totalHeight == 0`; we still allocate `lineH` for
                // the row band so the gutter remains visible.
                let contentAttr = buildContentAttributed(
                    content: line.content, font: font,
                    tokens: lineMap?[line.content])
                let contentLayout = TextLayout.make(
                    attributed: contentAttr, maxWidth: contentMaxWidth)
                let rowH = max(lineH, contentLayout.totalHeight)

                let lineRect = CGRect(
                    x: originX, y: y,
                    width: maxWidth, height: rowH)
                let gutterRect = CGRect(
                    x: originX, y: y, width: gutterWidth, height: rowH)
                let contentLenU16 = (line.content as NSString).length

                // Each preceding content row contributes its content
                // length + 1 (newline). The first row starts at 0.
                let globalStart =
                    hasEmittedContent
                    ? (runningContentChars + 1)
                    : 0
                rows.append(
                    Row(
                        lineRect: lineRect,
                        gutterRect: gutterRect,
                        lineBg: DiffColors.dynamicContentBg(effectiveType),
                        gutterBg: DiffColors.dynamicGutterBg(effectiveType),
                        prefixLine: prefixLine,
                        prefixBaseline: CGPoint(
                            x: originX, y: y + font.ascender),
                        contentLayout: contentLayout,
                        contentOrigin: CGPoint(
                            x: originX + prefixWidth, y: y),
                        isContent: true,
                        contentLength: contentLenU16,
                        contentText: line.content,
                        globalStart: globalStart))
                runningContentChars = globalStart + contentLenU16
                hasEmittedContent = true
                y += rowH
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

        // Copy button — **overlay** at the card's top-right corner.
        // Does not steal vertical space from the rows; sits on top of
        // whatever lines flow underneath it. Same visual recipe as the
        // cell-margin gutter (`BlockCellView+Gutter.swift`): 18pt hit
        // zone hosting an 11pt SF Symbol, anchored at
        // `diffHeaderCopyRightInset` (the corner-radius pivot).
        // Vertical center sits one corner-radius below the top edge so
        // the hit zone clears the rounded top corner.
        let copyHitSize = BlockStyle.gutterHitSize
        let copyRightInset = BlockStyle.diffHeaderCopyRightInset
        let overlayTopInset = BlockStyle.diffOverlayTopInset
        let copyHit: CGRect?
        let copyCenterPt: CGPoint?
        if maxWidth >= copyHitSize + 2 * copyRightInset {
            let cx = container.maxX - copyRightInset - copyHitSize / 2
            let cy = container.minY + overlayTopInset + copyHitSize / 2
            copyCenterPt = CGPoint(x: cx, y: cy)
            copyHit = CGRect(
                x: cx - copyHitSize / 2,
                y: cy - copyHitSize / 2,
                width: copyHitSize,
                height: copyHitSize)
        } else {
            copyCenterPt = nil
            copyHit = nil
        }

        // Language badge — overlay, left of the copy button at the
        // same vertical centre. `LanguageDetection.language(for:)`
        // returns lowercased highlight.js names; we render verbatim.
        // Dropped when the language is unknown or the available width
        // would force the pill to overlap the copy button.
        let langName = LanguageDetection.language(for: diff.filePath)
        let (langText, langBadgeRect) = makeLangBadge(
            name: langName,
            container: container,
            copyHitRect: copyHit,
            overlayCenterY: copyCenterPt?.y
                ?? (container.minY + overlayTopInset + copyHitSize / 2))

        return DiffLayout(
            containerRect: container,
            copyButtonId: copyButtonId,
            copyHitRect: copyHit,
            copyCenter: copyCenterPt,
            copyText: copyText,
            langBadgeRect: langBadgeRect,
            langText: langText,
            rows: rows,
            contentLength: runningContentChars)
    }

    /// Build the language-badge rect when there's enough room left of
    /// the copy button to host it. `overlayCenterY` is the vertical
    /// centre the badge shares with the copy button.
    nonisolated private static func makeLangBadge(
        name: String?,
        container: CGRect,
        copyHitRect: CGRect?,
        overlayCenterY: CGFloat
    ) -> (text: String?, rect: CGRect?) {
        guard let name, !name.isEmpty else { return (nil, nil) }
        let font = BlockStyle.diffHeaderBadgeFont
        let textW = textWidth(name, attrs: [.font: font])
        let badgeW = textW + 2 * BlockStyle.diffHeaderBadgeHorizontalPadding
        let badgeH = BlockStyle.diffHeaderBadgeHeight
        // Right edge: just left of the copy button's hit zone, or — if
        // the copy button was suppressed — flush against the same
        // pivot the copy button would have used.
        let rightEdge: CGFloat
        if let copyHitRect {
            rightEdge = copyHitRect.minX - BlockStyle.diffHeaderBadgeToCopyGap
        } else {
            rightEdge = container.maxX - BlockStyle.diffHeaderCopyRightInset
        }
        let badgeMinX = rightEdge - badgeW
        guard badgeMinX >= container.minX + BlockStyle.diffHeaderCopyRightInset else {
            return (nil, nil)
        }
        let rect = CGRect(
            x: badgeMinX,
            y: overlayCenterY - badgeH / 2,
            width: badgeW,
            height: badgeH)
        return (name, rect)
    }

    nonisolated private static func empty(
        copyButtonId: UUID, copyText: String
    ) -> DiffLayout {
        DiffLayout(
            containerRect: .zero,
            copyButtonId: copyButtonId,
            copyHitRect: nil,
            copyCenter: nil,
            copyText: copyText,
            langBadgeRect: nil,
            langText: nil,
            rows: [],
            contentLength: 0)
    }

    nonisolated private static func expandTopFill(_ row: Row, by pad: CGFloat) -> Row {
        Row(
            lineRect: CGRect(
                x: row.lineRect.minX, y: row.lineRect.minY - pad,
                width: row.lineRect.width,
                height: row.lineRect.height + pad),
            gutterRect: row.gutterRect.isEmpty
                ? .zero
                : CGRect(
                    x: row.gutterRect.minX, y: row.gutterRect.minY - pad,
                    width: row.gutterRect.width,
                    height: row.gutterRect.height + pad),
            lineBg: row.lineBg, gutterBg: row.gutterBg,
            prefixLine: row.prefixLine,
            prefixBaseline: row.prefixBaseline,
            contentLayout: row.contentLayout,
            contentOrigin: row.contentOrigin,
            isContent: row.isContent,
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
            gutterRect: row.gutterRect.isEmpty
                ? .zero
                : CGRect(
                    x: row.gutterRect.minX, y: row.gutterRect.minY,
                    width: row.gutterRect.width,
                    height: row.gutterRect.height + pad),
            lineBg: row.lineBg, gutterBg: row.gutterBg,
            prefixLine: row.prefixLine,
            prefixBaseline: row.prefixBaseline,
            contentLayout: row.contentLayout,
            contentOrigin: row.contentOrigin,
            isContent: row.isContent,
            contentLength: row.contentLength,
            contentText: row.contentText,
            globalStart: row.globalStart)
    }

    nonisolated private static func textWidth(
        _ s: String, attrs: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    /// Build the per-row prefix attributed string: ` NNN ` (gutter)
    /// + ` ± ` (sign). Same fonts / colors as the original
    /// `buildLineAttributed`, just split off so the content half can
    /// be typeset independently.
    nonisolated private static func buildPrefixAttributed(
        line: DiffEngine.Line,
        effectiveType: DiffEngine.Line.LineType,
        digits: Int,
        font: NSFont,
        suppressSign: Bool
    ) -> NSAttributedString {
        let lineNoStr = line.lineNo.map(String.init) ?? ""
        let padded =
            String(repeating: " ", count: max(0, digits - lineNoStr.count))
            + lineNoStr

        let result = NSMutableAttributedString()
        result.append(
            NSAttributedString(
                string: " \(padded) ",
                attributes: [
                    .font: font,
                    .foregroundColor: BlockStyle.diffGutterForeground,
                ]))

        // New-file mode has no diff chrome to show — skip the sign
        // glyph entirely so the caller's `signWidth = 0` matches.
        guard !suppressSign else { return result }

        let sign: String
        let signColor: NSColor
        switch effectiveType {
        case .add:
            sign = "+"
            signColor = BlockStyle.diffSignAddForeground
        case .del:
            sign = "-"
            signColor = BlockStyle.diffSignDelForeground
        case .context:
            sign = " "
            signColor = NSColor.labelColor
        }
        result.append(
            NSAttributedString(
                string: " \(sign) ",
                attributes: [
                    .font: font,
                    .foregroundColor: signColor,
                ]))
        return result
    }

    /// Build the per-row content attributed string — the source text,
    /// optionally token-coloured. Empty content (a blank diff line)
    /// returns an empty attributed string, which `TextLayout.make`
    /// short-circuits to `.empty`.
    nonisolated private static func buildContentAttributed(
        content: String,
        font: NSFont,
        tokens: [SyntaxToken]?
    ) -> NSAttributedString {
        guard !content.isEmpty else { return NSAttributedString() }
        if let tokens, !tokens.isEmpty {
            let result = NSMutableAttributedString()
            for token in tokens {
                let color = colorForToken(scope: token.scope)
                result.append(
                    NSAttributedString(
                        string: token.text,
                        attributes: [
                            .font: font,
                            .foregroundColor: color,
                        ]))
            }
            return result
        }
        return NSAttributedString(
            string: content,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
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

        var lastContentRow: Row?
        for row in rows where row.isContent {
            if point.y < row.lineRect.minY {
                if let prev = lastContentRow {
                    return prev.globalStart + prev.contentLength
                }
                return row.globalStart
            }
            if point.y <= row.lineRect.maxY {
                return Self.charIndex(in: row, atLocalPoint: point)
            }
            lastContentRow = row
        }
        if let last = lastContentRow {
            return last.globalStart + last.contentLength
        }
        return 0
    }

    /// Selection rects covering the half-open range `[loChar, hiChar)`.
    /// One rect per visual line fragment that intersects the range;
    /// wrap-continuation lines emit their own rects, indented to the
    /// content column.
    ///
    /// Rects are clamped horizontally to the container so a long
    /// wrapped line never bleeds past the rounded card edge — same
    /// invariant as the pre-wrap layout (which clamped to handle the
    /// "long single CTLine spills past the card" case).
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
            if hi == lo && lo == rowStart { continue }
            let localLo = lo - rowStart
            let localHi = hi - rowStart
            let nsRange = NSRange(
                location: localLo, length: max(0, localHi - localLo))
            guard nsRange.length > 0 else { continue }
            let layoutRects = row.contentLayout.selectionRects(for: nsRange)
            for r in layoutRects {
                let absRect = r.offsetBy(
                    dx: row.contentOrigin.x, dy: row.contentOrigin.y)
                let clampedLo = max(containerMinX, min(absRect.minX, containerMaxX))
                let clampedHi = max(containerMinX, min(absRect.maxX, containerMaxX))
                guard clampedHi > clampedLo else { continue }
                out.append(
                    CGRect(
                        x: clampedLo,
                        y: absRect.minY,
                        width: clampedHi - clampedLo,
                        height: absRect.height))
            }
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
            let nlIndex = rowEnd
            let trailingNlInRange = (nlIndex >= loChar && nlIndex < hiChar)
            let bodyOverlap =
                (hiChar > rowStart && loChar < rowEnd)
                || (rowStart == rowEnd && loChar <= rowStart && rowStart < hiChar)
            guard bodyOverlap || trailingNlInRange else { continue }
            let lo = max(loChar, rowStart)
            let hi = min(hiChar, rowEnd)
            let localLo = lo - rowStart
            let localHi = max(0, hi - rowStart)
            let nsText = row.contentText as NSString
            let slice =
                (localHi > localLo)
                ? nsText.substring(
                    with: NSRange(
                        location: localLo,
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
            let attr = NSAttributedString(string: row.contentText)
            let word = attr.doubleClick(at: local)
            return NSRange(
                location: rowStart + word.location,
                length: word.length)
        }
        return nil
    }

    /// Helper: layout-local point → content-only char index.
    /// Points landing in the gutter / sign columns (`x` left of
    /// `contentOrigin.x`) clamp to the start of the visual line the
    /// point falls in. Points past the content edge clamp to the
    /// visual line's end. Points past the row's last visual line
    /// (e.g. when content's `totalHeight < lineH` and the click lands
    /// in the bottom slack) clamp to the row's content end.
    nonisolated private static func charIndex(in row: Row, atLocalPoint p: CGPoint) -> Int {
        // Translate to content-layout local coords (top-left of the
        // content layout is `row.contentOrigin`).
        let localP = CGPoint(
            x: p.x - row.contentOrigin.x,
            y: p.y - row.contentOrigin.y)
        // `TextLayout.characterIndex` handles out-of-bounds clamping:
        // y above the layout → 0; y below → length; x outside a line
        // → the line's start/end.
        let idx = row.contentLayout.characterIndex(at: localP)
        let clamped = max(0, min(row.contentLength, idx))
        return row.globalStart + clamped
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

    /// Container fill + add/del row tint + gutter tint + language
    /// badge background. Painted by `BlockCellView` before the
    /// selection band. All passes clipped to the rounded card so long
    /// lines / extended top+bottom fills don't bleed past the corners.
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
        // Pass 1 — line backgrounds (full width, full wrapped height).
        for row in rows where row.lineBg.alphaComponent > 0 {
            ctx.setFillColor(row.lineBg.cgColor)
            ctx.fill(row.lineRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        // Pass 2 — gutter backgrounds layered over line backgrounds.
        // Gutter tint is first-visual-line only; continuation visual
        // lines fall through to the underlying lineBg.
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

        // Prefix glyphs (gutter + sign) — single CTLine per content
        // row, drawn at the first visual line's baseline.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in rows {
            guard let prefix = row.prefixLine else { continue }
            ctx.textPosition = CGPoint(
                x: origin.x + row.prefixBaseline.x,
                y: origin.y + row.prefixBaseline.y)
            CTLineDraw(prefix, ctx)
        }
        ctx.restoreGState()

        // Content glyphs — wrapped TextLayout handles its own text
        // matrix flip.
        for row in rows {
            row.contentLayout.draw(
                in: ctx,
                origin: CGPoint(
                    x: origin.x + row.contentOrigin.x,
                    y: origin.y + row.contentOrigin.y))
        }

        ctx.restoreGState()
    }

    /// Top-right overlay chrome — language badge pill + copy button.
    /// Drawn after `draw(in:origin:)` so glyphs that would otherwise
    /// flow under the badge / button stay legible (chrome composites
    /// on top of content). The whole pass is clipped to the rounded
    /// card so badge / hover bg never bleed past the corner.
    ///
    /// `hovered` toggles the gutter-style rounded hover background
    /// behind the SF Symbol; `copied` swaps `doc.on.doc` → `checkmark`
    /// for the post-click flash. The copy glyph itself is always
    /// drawn — the affordance is persistently visible.
    func drawHeaderChrome(
        in ctx: CGContext, origin: CGPoint,
        hovered: Bool, copied: Bool
    ) {
        guard !containerRect.isEmpty else { return }
        // Clip to the rounded card so a top-right overlay never spills
        // past the corner curve.
        let containerAtScreen = containerRect.offsetBy(dx: origin.x, dy: origin.y)
        let clipPath = CGPath(
            roundedRect: containerAtScreen,
            cornerWidth: BlockStyle.structuralCornerRadius,
            cornerHeight: BlockStyle.structuralCornerRadius,
            transform: nil)
        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()

        // Language badge pill — translucent fill + monospaced label.
        if let badge = langBadgeRect, let text = langText {
            let badgeAtScreen = badge.offsetBy(dx: origin.x, dy: origin.y)
            let badgePath = CGPath(
                roundedRect: badgeAtScreen,
                cornerWidth: BlockStyle.diffHeaderBadgeCornerRadius,
                cornerHeight: BlockStyle.diffHeaderBadgeCornerRadius,
                transform: nil)
            ctx.setFillColor(BlockStyle.diffHeaderBadgeBackground.cgColor)
            ctx.addPath(badgePath)
            ctx.fillPath()

            let font = BlockStyle.diffHeaderBadgeFont
            let attr = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: BlockStyle.diffHeaderBadgeForeground,
                ])
            let line = CTLineCreateWithAttributedString(attr)
            // Y-down baseline: visible glyph extent
            // `[baseline - ascender, baseline - descender]` centred on
            // `badge.midY` ⇒ baseline = midY + (asc + desc)/2.
            let baseline = badge.midY + (font.ascender + font.descender) / 2
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(
                x: origin.x + badge.minX + BlockStyle.diffHeaderBadgeHorizontalPadding,
                y: origin.y + baseline)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        // Copy button — gutter-style chrome. Always visible; hover bg
        // and glyph swap track the runtime state.
        if let hitRect = copyHitRect, let center = copyCenter {
            let hitAtScreen = hitRect.offsetBy(dx: origin.x, dy: origin.y)
            if hovered {
                let path = CGPath(
                    roundedRect: hitAtScreen,
                    cornerWidth: BlockStyle.gutterHoverCornerRadius,
                    cornerHeight: BlockStyle.gutterHoverCornerRadius,
                    transform: nil)
                ctx.setFillColor(BlockStyle.gutterHoverBackground.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }

            let name = copied ? "checkmark" : "doc.on.doc"
            let tint: NSColor =
                hovered
                ? BlockStyle.gutterHoverForeground
                : BlockStyle.gutterIdleForeground
            let weight: NSFont.Weight = copied ? .semibold : .regular
            let baseConfig = NSImage.SymbolConfiguration(
                pointSize: BlockStyle.gutterSymbolPointSize, weight: weight)
            let colorConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
            let config = baseConfig.applying(colorConfig)
            if let symbol = NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            {
                let size = symbol.size
                let drawRect = CGRect(
                    x: origin.x + center.x - size.width / 2,
                    y: origin.y + center.y - size.height / 2,
                    width: size.width,
                    height: size.height)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(
                    cgContext: ctx, flipped: true)
                symbol.draw(
                    in: drawRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        ctx.restoreGState()
    }
}

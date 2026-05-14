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
/// Not implemented. `ToolGroupLayout.selectionAdapter` is `nil` for
/// the entire row, so the cell doesn't reach into this layout for
/// selection rects.
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
    }

    let rows: [Row]

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
            return DiffLayout(containerRect: .zero, rows: [])
        }

        let suppressAdd = diff.isNewFile
        let hunks = DiffEngine.computeHunks(
            old: diff.effectiveOldString, new: diff.newString)
        guard !hunks.isEmpty else {
            return DiffLayout(containerRect: .zero, rows: [])
        }

        let font = BlockStyle.diffBodyFont
        let lineH = font.ascender - font.descender

        // Gutter width: padded to the widest line number across all
        // hunks plus a space on each side.
        let maxLineNo = hunks.flatMap(\.lines).compactMap(\.lineNo).max() ?? 0
        let digits = max(2, String(maxLineNo).count)
        let gutterText = String(repeating: " ", count: digits + 2) // " NNN "
        let gutterWidth = textWidth(gutterText, attrs: [.font: font])

        var rows: [Row] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
        var y: CGFloat = originY

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
                        y: y + font.ascender)))
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
                rows.append(Row(
                    lineRect: lineRect,
                    gutterRect: gutterRect,
                    lineBg: DiffColors.dynamicContentBg(effectiveType),
                    gutterBg: DiffColors.dynamicGutterBg(effectiveType),
                    line: ctLine,
                    baseline: CGPoint(x: originX, y: y + font.ascender)))
                y += lineH
            }
        }

        let containerHeight = y - originY
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: containerHeight)
        return DiffLayout(containerRect: container, rows: rows)
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
        } else {
            let content = line.content.isEmpty ? " " : line.content
            result.append(NSAttributedString(string: content, attributes: [
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

    // MARK: - Draw

    /// Rounded-card fill. Called *before* glyphs paint so the selection
    /// band (if any) composites on top of it. `ToolGroupLayout.drawBackplate`
    /// forwards into this for every expanded item.
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
        ctx.restoreGState()
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        guard !containerRect.isEmpty else { return }
        // Clip body to the rounded card so long lines don't bleed past
        // the corners.
        ctx.saveGState()
        let containerAtScreen = containerRect.offsetBy(dx: origin.x, dy: origin.y)
        let clipPath = CGPath(
            roundedRect: containerAtScreen,
            cornerWidth: BlockStyle.structuralCornerRadius,
            cornerHeight: BlockStyle.structuralCornerRadius,
            transform: nil)
        ctx.addPath(clipPath)
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

        // Pass 3 — glyphs.
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

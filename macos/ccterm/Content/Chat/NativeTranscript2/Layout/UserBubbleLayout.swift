import AppKit
import CoreText

/// Right-aligned chat bubble for user-typed messages.
///
/// Layout is **stateless**: short text renders in full; long text (≥
/// `userBubbleCollapseThreshold + userBubbleMinHiddenLines` typeset
/// lines) hard-truncates the visible block to `userBubbleCollapseThreshold`
/// lines with a tail "…" on the last line, plus a `>` chevron anchored
/// to the bubble's bottom-right rounded corner. Tapping the chevron
/// opens a SwiftUI sheet with the full text — that path is the *only*
/// place fold state lives, owned by `Transcript2Controller.pendingUserBubbleSheet`
/// and consumed by `NativeTranscript2View`'s `.sheet(item:)`.
///
/// ### Why no in-cell expanded mode
///
/// A previous design carried `isExpanded` on `Block.Kind` and toggled
/// through `.update`. It worked but conflated two concerns: (a) the
/// bubble's *display geometry* (line count, ellipsis), and (b) "where
/// to read the rest" (in-place vs. modal). A sheet handles (b) without
/// the bubble row swinging between two heights, and removes every
/// stateful API surface from this layout.
///
/// ### Geometry summary (layout-local coords, y-down)
///
/// ```
/// ┌── layout (width = maxWidth) ─────────────────────────────┐
/// │                            ┌── bubbleRect ─────────────┐ │
/// │                            │ text…                     │ │
/// │                            │ text…                     │ │
/// │                            │ text…  …                  │ │
/// │                            │                       >   │ │   ← chevron
/// │                            └───────────────────────────┘ │
/// └──────────────────────────────────────────────────────────┘
/// ```
///
/// The chevron sits at `(bubble.maxX − cornerRadius, bubble.maxY −
/// cornerRadius)` so its inset to the right and bottom edges is
/// uniform (== `cornerRadius`), reading as anchored to the rounded
/// corner rather than tied to the last line's baseline. It does **not**
/// participate in text wrapping; truncation reserves a small extra gap
/// (`truncationGuardWidth`) so the "…" never visually crowds the
/// chevron column.
struct UserBubbleLayout: @unchecked Sendable {
    /// Original plain text. Carried so the SwiftUI sheet can display the
    /// full content unchanged after the layout truncated it for in-cell
    /// rendering.
    let fullText: String

    /// Lines actually drawn. When folded, the last entry is a CT-truncated
    /// "…"-tail line whose `CTLineGetStringRange` still spans the full
    /// remaining source (Apple's documented behavior). That means a drag
    /// onto the tail can yield a `string()` that includes hidden text —
    /// **accepted as feature**: the chevron sheet is the canonical path
    /// to "see / copy everything", so an opportunistic drag-copy just
    /// short-circuits there. No special per-line bookkeeping.
    let lines: [CTLine]
    let lineOrigins: [CGPoint]
    let lineMetrics: [LineMetrics]

    let bubbleRect: CGRect
    /// Top-left of the text region inside the bubble — equals
    /// `bubbleRect.origin + (bubbleHorizontalPadding, bubbleVerticalPadding)`.
    let textOriginInRow: CGPoint

    /// Click target for the "open full message" chevron. `nil` when the
    /// bubble fits the full text without truncation.
    let chevronHitRect: CGRect?
    /// Center of the chevron glyph — anchored to the bubble's bottom-right
    /// corner (`maxX − cornerRadius, maxY − cornerRadius`) so right and
    /// bottom insets are uniform.
    let chevronCenter: CGPoint?

    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    struct LineMetrics: Sendable {
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Extra slack subtracted from the truncation width so "…" lands
    /// noticeably left of the bubble's right padding strip and never
    /// crowds the chevron column. Tuned to `chevronHitSize + a small
    /// optical buffer` (≈ 24pt) — without this, "…" sits about 8pt from
    /// `>` and reads as a single visual unit.
    nonisolated private static let truncationGuardWidth: CGFloat = 24

    nonisolated static func make(text: String, maxWidth: CGFloat) -> UserBubbleLayout {
        let maxBubbleWidth = max(120, min(
            BlockStyle.userBubbleMaxWidth,
            maxWidth - BlockStyle.bubbleMinLeftGutter))
        let textMaxWidth = max(40, maxBubbleWidth - 2 * BlockStyle.bubbleHorizontalPadding)

        let attributed = BlockStyle.userBubbleAttributed(text: text)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let allLines = typesetAll(
            typesetter: typesetter,
            length: attributed.length,
            maxWidth: textMaxWidth)

        let threshold = BlockStyle.userBubbleCollapseThreshold
        let minHidden = BlockStyle.userBubbleMinHiddenLines
        let shouldFold = allLines.count >= threshold + minHidden

        let drawnLines: [CTLine]
        if shouldFold {
            let prefix = Array(allLines.prefix(threshold - 1))
            let prefixCharCount = prefix.reduce(0) { acc, l in
                acc + CTLineGetStringRange(l).length
            }
            drawnLines = truncatedFold(
                typesetter: typesetter,
                prefix: prefix,
                prefixCharCount: prefixCharCount,
                attributedLength: attributed.length,
                truncationWidth: max(40, textMaxWidth - truncationGuardWidth))
        } else {
            drawnLines = allLines
        }

        let stack = stackLines(drawnLines)

        let displayedTextWidth = stack.lineWidths.max() ?? 0
        let bubbleWidth = min(
            maxBubbleWidth,
            displayedTextWidth + 2 * BlockStyle.bubbleHorizontalPadding)
        let bubbleHeight = stack.totalHeight + 2 * BlockStyle.bubbleVerticalPadding
        let bubbleX = maxWidth - bubbleWidth
        let bubbleRect = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
        let textOrigin = CGPoint(
            x: bubbleRect.minX + BlockStyle.bubbleHorizontalPadding,
            y: bubbleRect.minY + BlockStyle.bubbleVerticalPadding)

        // Chevron — only when folded. Centered on the bubble's bottom-right
        // rounded-corner pivot: equal `cornerRadius` inset from right and
        // bottom edges. Reads as a corner affordance, not as a tail of
        // the last line.
        let chevronCenter: CGPoint?
        let chevronHit: CGRect?
        if shouldFold {
            let r = BlockStyle.bubbleCornerRadius
            let center = CGPoint(x: bubbleRect.maxX - r, y: bubbleRect.maxY - r)
            let half = BlockStyle.chevronHitSize / 2
            chevronCenter = center
            chevronHit = CGRect(
                x: center.x - half, y: center.y - half,
                width: BlockStyle.chevronHitSize,
                height: BlockStyle.chevronHitSize)
        } else {
            chevronCenter = nil
            chevronHit = nil
        }

        return UserBubbleLayout(
            fullText: text,
            lines: drawnLines,
            lineOrigins: stack.lineOrigins,
            lineMetrics: stack.lineMetrics,
            bubbleRect: bubbleRect,
            textOriginInRow: textOrigin,
            chevronHitRect: chevronHit,
            chevronCenter: chevronCenter,
            totalHeight: bubbleHeight,
            measuredWidth: maxWidth)
    }

    // MARK: - Typesetting helpers

    nonisolated private static func typesetAll(
        typesetter: CTTypesetter, length: Int, maxWidth: CGFloat
    ) -> [CTLine] {
        var lines: [CTLine] = []
        var start: CFIndex = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            guard count > 0 else { break }
            lines.append(CTTypesetterCreateLine(
                typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    /// `keepFirst` typeset lines unchanged, then a single
    /// `CTLineCreateTruncatedLine` over all remaining characters with an
    /// `…` token spliced in at the right edge. `truncationWidth` is
    /// already shrunk by `truncationGuardWidth` so the resulting "…"
    /// sits clear of the chevron column.
    nonisolated private static func truncatedFold(
        typesetter: CTTypesetter,
        prefix: [CTLine],
        prefixCharCount: Int,
        attributedLength: Int,
        truncationWidth: CGFloat
    ) -> [CTLine] {
        let combined = CTTypesetterCreateLine(
            typesetter,
            CFRange(location: prefixCharCount,
                    length: attributedLength - prefixCharCount))
        let token = CTLineCreateWithAttributedString(NSAttributedString(
            string: "\u{2026}",
            attributes: [
                .font: BlockStyle.paragraphFont,
                .foregroundColor: NSColor.labelColor,
            ]) as CFAttributedString)
        let truncated = CTLineCreateTruncatedLine(
            combined, Double(truncationWidth), .end, token) ?? combined
        return prefix + [truncated]
    }

    private struct StackedLayout {
        let lineOrigins: [CGPoint]
        let lineMetrics: [LineMetrics]
        let lineWidths: [CGFloat]
        let totalHeight: CGFloat
    }

    nonisolated private static func stackLines(_ lines: [CTLine]) -> StackedLayout {
        var origins: [CGPoint] = []
        var metrics: [LineMetrics] = []
        var widths: [CGFloat] = []
        var y: CGFloat = 0
        for line in lines {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let typoWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            y += ascent
            origins.append(CGPoint(x: 0, y: y))
            metrics.append(LineMetrics(ascent: ascent, descent: descent))
            widths.append(CGFloat(typoWidth))
            y += descent + leading
        }
        return StackedLayout(
            lineOrigins: origins, lineMetrics: metrics,
            lineWidths: widths, totalHeight: y)
    }

    // MARK: - Selection adapter

    /// Same shape as `TextLayout.selectionAdapter`, using `CTLineGetStringRange`
    /// directly per line. The truncated tail is treated as a regular line —
    /// drag onto it may end at the source-string suffix's tail, in which
    /// case `string()` returns hidden content too. That's intentional:
    /// users wanting "see / copy everything" go through the chevron sheet,
    /// and an opportunistic drag-copy that includes the hidden part is
    /// no worse than a quick path to the same result.
    var selectionAdapter: SelectionAdapter {
        let textOrigin = textOriginInRow
        let lines = self.lines
        let origins = self.lineOrigins
        let metrics = self.lineMetrics
        let totalLength = lines.reduce(0) { $0 + CTLineGetStringRange($1).length }
        let source = fullText as NSString
        let full = SelectionRange(
            start: .text(char: 0), end: .text(char: totalLength))

        return SelectionAdapter(
            fullRange: full,
            unitRange: { _ in full },
            hitTest: { p in
                let textP = CGPoint(x: p.x - textOrigin.x, y: p.y - textOrigin.y)
                return .text(char: Self.charIndex(
                    lines: lines, origins: origins, metrics: metrics, at: textP))
            },
            rects: { a, b in
                guard case .text(let i1) = a, case .text(let i2) = b
                else { return [] }
                let lo = min(i1, i2), hi = max(i1, i2)
                guard hi > lo else { return [] }
                return Self.selectionRects(
                    lines: lines, origins: origins, metrics: metrics,
                    range: NSRange(location: lo, length: hi - lo))
                    .map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
            },
            string: { a, b in
                guard case .text(let i1) = a, case .text(let i2) = b
                else { return "" }
                let lo = min(i1, i2), hi = max(i1, i2)
                guard hi > lo, hi <= source.length else { return "" }
                return source.substring(with: NSRange(location: lo, length: hi - lo))
            },
            wordBoundary: { _ in nil })
    }

    nonisolated private static func charIndex(
        lines: [CTLine], origins: [CGPoint], metrics: [LineMetrics], at p: CGPoint
    ) -> Int {
        guard !lines.isEmpty else { return 0 }
        if p.y < origins[0].y - metrics[0].ascent { return 0 }
        for i in 0 ..< lines.count {
            let bottom = origins[i].y + metrics[i].descent
            guard p.y <= bottom else { continue }
            let idx = CTLineGetStringIndexForPosition(lines[i], CGPoint(x: p.x, y: 0))
            return idx == kCFNotFound
                ? CTLineGetStringRange(lines[i]).location
                : idx
        }
        return lines.reduce(0) { $0 + CTLineGetStringRange($1).length }
    }

    nonisolated private static func selectionRects(
        lines: [CTLine], origins: [CGPoint], metrics: [LineMetrics], range: NSRange
    ) -> [CGRect] {
        let selStart = range.location
        let selEnd = range.location + range.length
        var rects: [CGRect] = []
        for (i, line) in lines.enumerated() {
            let r = CTLineGetStringRange(line)
            let lineStart = r.location
            let lineEnd = lineStart + r.length
            let lo = max(selStart, lineStart)
            let hi = min(selEnd, lineEnd)
            guard hi > lo else { continue }
            let xStart = CTLineGetOffsetForStringIndex(line, lo, nil)
            let xEnd = CTLineGetOffsetForStringIndex(line, hi, nil)
            let baseline = origins[i].y
            let ascent = metrics[i].ascent
            let descent = metrics[i].descent
            rects.append(CGRect(
                x: xStart, y: baseline - ascent,
                width: max(0, xEnd - xStart), height: ascent + descent))
        }
        return rects
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, origin: CGPoint) {
        let bubbleAtScreen = bubbleRect.offsetBy(dx: origin.x, dy: origin.y)
        let bubblePath = CGPath(
            roundedRect: bubbleAtScreen,
            cornerWidth: BlockStyle.bubbleCornerRadius,
            cornerHeight: BlockStyle.bubbleCornerRadius,
            transform: nil)

        // 1) Bubble fill.
        ctx.saveGState()
        ctx.setFillColor(BlockStyle.bubbleFillColor.cgColor)
        ctx.addPath(bubblePath)
        ctx.fillPath()
        ctx.restoreGState()

        // 2) Text — Core Text glyphs stacked at each line's origin.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (line, lineOrigin) in zip(lines, lineOrigins) {
            ctx.textPosition = CGPoint(
                x: textOriginInRow.x + lineOrigin.x + origin.x,
                y: textOriginInRow.y + lineOrigin.y + origin.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()

        // 3) Chevron at the corner pivot.
        if let center = chevronCenter {
            drawChevron(in: ctx, centerInRow: CGPoint(
                x: center.x + origin.x, y: center.y + origin.y))
        }
    }

    private func drawChevron(in ctx: CGContext, centerInRow center: CGPoint) {
        // `>` glyph — V opening leftwards. `halfH > halfW` gives an apex
        // angle ≈ 77° (computed: cos(θ) = (4w² − h²)/(4w² + h²) with
        // w = 2.5, h = 4 → θ ≈ 77°). Wider than text-character `>` (~35°)
        // and a touch wider than SF Symbols' default chevron.right
        // (~70°), reading as "open / friendly" rather than "navigational
        // / minimal" — appropriate for a click-to-expand affordance.
        let halfW = BlockStyle.chevronSize * 0.25
        let halfH = BlockStyle.chevronSize * 0.40
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - halfW, y: center.y - halfH))
        path.addLine(to: CGPoint(x: center.x + halfW, y: center.y))
        path.addLine(to: CGPoint(x: center.x - halfW, y: center.y + halfH))

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

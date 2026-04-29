import AppKit
import CoreText

/// Immutable Core Text layout — pure function of (attributed string, max width).
///
/// Coordinate system: y grows downward (matches NSTableView's flipped row coords).
/// `lineOrigins[i].y` is the baseline distance from the top of the layout.
///
/// `@unchecked Sendable`: Swift's type system can't see that `CTLine` is
/// thread-safe. Apple's Core Text Programming Guide documents `CTLine` as
/// immutable / safe to share across threads — we promise not to mutate the
/// `[CTLine]` after construction.
///
/// Performance (Apple Silicon, system font, width=600, Swift `-O`; see
/// `cctermTests/NativeTranscript2/TextLayoutBenchmarkTests.swift`):
///
/// | text                | make/100ch | draw warm/100ch |
/// |---------------------|-----------:|----------------:|
/// | ASCII paragraph 14pt (steady) | ~15–20μs  | ~12μs |
/// | CJK   paragraph 14pt (steady) | ~100μs    | ~34μs |
/// | ASCII heading 22pt           | ~15μs     | ~27μs |
///
/// Both are O(n). CJK is 5–8× slower than ASCII at every step (heavier shaping).
/// `make` cost is ≥95% in `CTTypesetterCreateWithAttributedString` + per-line
/// `CTTypesetterSuggestLineBreak`; the per-line `CTTypesetterCreateLine` +
/// `CTLineGetTypographicBounds` are <5%. **Don't write a height-only fast path
/// that drops `CTLine` creation — it saves nothing.** The make/draw split pays
/// off only for long text + repeat draws (e.g. 10k-char paragraph: draw is
/// 0.21× of make); short text the split is roughly neutral.
/// Draw cost is insensitive to layout instance — CG glyph cache is
/// process-global and warms in <1 frame.
///
/// ### Decoration extraction
///
/// `CTLineDraw` only paints glyphs — it does **not** honor
/// `.backgroundColor` and does **not** respond to `.link` clicks. Both
/// require a post-typeset scan over runs to compute screen-space rects:
/// inline-code backgrounds (drawn by `draw(in:origin:)` itself), and link
/// hot zones (consumed by the cell for hit-testing + cursor). Done once at
/// `make` time so layout reuse benefits include the decoration data.
struct TextLayout: @unchecked Sendable {
    let lines: [CTLine]
    let lineOrigins: [CGPoint]
    /// Per-line ascent/descent. Used by selection rect generation and by
    /// hit-testing to find the line whose vertical band contains a point.
    /// Promoted from a local `make`-time variable into stored state because
    /// recomputing `CTLineGetTypographicBounds` on every selection update
    /// during a drag is wasted work.
    let lineMetrics: [LineMetrics]
    let totalHeight: CGFloat
    let measuredWidth: CGFloat
    /// Inline code backgrounds in layout-local coords (y down, top-left).
    /// Tight to the line's ascent/descent — no leading — so multi-line
    /// paragraphs keep their bg boxes inside each line's vertical band
    /// instead of bleeding into the next line.
    let codeBackgrounds: [CGRect]
    /// Link hit zones in layout-local coords. Multi-line links produce one
    /// rect per line.
    let links: [LinkHit]

    struct LineMetrics: Sendable {
        let ascent: CGFloat
        let descent: CGFloat
    }

    struct LinkHit: Sendable {
        let rect: CGRect
        let url: URL
    }

    /// Total typeset character count. Equal to the source attributed
    /// string's length when `make` ran to completion (typesetter
    /// consumed all characters).
    var length: Int {
        guard let last = lines.last else { return 0 }
        let r = CTLineGetStringRange(last)
        return r.location + r.length
    }

    nonisolated static let empty = TextLayout(
        lines: [], lineOrigins: [], lineMetrics: [],
        totalHeight: 0, measuredWidth: 0,
        codeBackgrounds: [], links: [])

    nonisolated static func make(attributed: NSAttributedString, maxWidth: CGFloat) -> TextLayout {
        guard attributed.length > 0, maxWidth > 0 else { return .empty }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var origins: [CGPoint] = []
        var metrics: [LineMetrics] = []
        var y: CGFloat = 0
        var start: CFIndex = 0

        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            guard count > 0 else { break }
            let line = CTTypesetterCreateLine(
                typesetter, CFRange(location: start, length: count))

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

            y += ascent
            origins.append(CGPoint(x: 0, y: y))
            metrics.append(LineMetrics(ascent: ascent, descent: descent))
            y += descent + leading
            lines.append(line)
            start += count
        }

        let (codeBackgrounds, links) = extractDecorations(
            lines: lines, origins: origins, metrics: metrics)

        return TextLayout(
            lines: lines, lineOrigins: origins, lineMetrics: metrics,
            totalHeight: y, measuredWidth: maxWidth,
            codeBackgrounds: codeBackgrounds, links: links)
    }

    /// Walks each line's runs once. The marker check is presence-only; the
    /// link check accepts both `URL` and `String` (CommonMark parsers
    /// commonly emit either). Per-run x extent is taken from
    /// `CTLineGetOffsetForStringIndex` — this is correct in the presence of
    /// kerning / RTL because CT computes the run's string-range endpoints
    /// in the line's typographic space.
    nonisolated private static func extractDecorations(
        lines: [CTLine],
        origins: [CGPoint],
        metrics: [LineMetrics]
    ) -> (codeBackgrounds: [CGRect], links: [LinkHit]) {
        var codeRects: [CGRect] = []
        var linkHits: [LinkHit] = []
        let codeKey = BlockStyle.inlineCodeAttributeKey
        let linkKey = NSAttributedString.Key.link

        for (lineIdx, line) in lines.enumerated() {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            let baseline = origins[lineIdx].y
            let ascent = metrics[lineIdx].ascent
            let descent = metrics[lineIdx].descent

            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let hasCode = attrs[codeKey] != nil
                let linkRaw = attrs[linkKey]
                guard hasCode || linkRaw != nil else { continue }

                let stringRange = CTRunGetStringRange(run)
                let xStart = CTLineGetOffsetForStringIndex(
                    line, stringRange.location, nil)
                let xEnd = CTLineGetOffsetForStringIndex(
                    line, stringRange.location + stringRange.length, nil)
                let rect = CGRect(
                    x: xStart,
                    y: baseline - ascent,
                    width: xEnd - xStart,
                    height: ascent + descent)

                if hasCode {
                    codeRects.append(rect)
                }
                if let linkRaw, let url = parseLink(linkRaw) {
                    linkHits.append(LinkHit(rect: rect, url: url))
                }
            }
        }
        return (codeRects, linkHits)
    }

    nonisolated private static func parseLink(_ raw: Any) -> URL? {
        if let url = raw as? URL { return url }
        if let nsurl = raw as? NSURL { return nsurl as URL }
        if let s = raw as? String { return URL(string: s) }
        return nil
    }

    // MARK: - Selection queries

    /// Insertion-point index at `point` (layout-local coords, y-down).
    /// Clamped to `[0, length]`. Used by drag-to-select hit-testing.
    ///
    /// - Above the first line: `0`.
    /// - Below the last line: `length`.
    /// - Inside or in the leading region above a line's bottom: the line's
    ///   `CTLineGetStringIndexForPosition` result; on the rare
    ///   `kCFNotFound` (very negative or very large x) we clamp to that
    ///   line's start or end. Modern CT clamps internally for in-range x,
    ///   so the explicit fallback is defensive.
    func characterIndex(at point: CGPoint) -> Int {
        guard !lines.isEmpty else { return 0 }

        if point.y < lineOrigins[0].y - lineMetrics[0].ascent { return 0 }

        for i in 0 ..< lines.count {
            let bottom = lineOrigins[i].y + lineMetrics[i].descent
            guard point.y <= bottom else { continue }
            let idx = CTLineGetStringIndexForPosition(
                lines[i], CGPoint(x: point.x, y: 0))
            if idx == kCFNotFound {
                let r = CTLineGetStringRange(lines[i])
                return point.x < 0 ? r.location : r.location + r.length
            }
            return idx
        }
        return length
    }

    /// Selection-highlight rects (one per line fragment that intersects
    /// `range`). Each rect is tight to the line's ascent/descent in
    /// layout-local coords, matching `NSTextView`'s default selection
    /// highlight geometry.
    func selectionRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0, !lines.isEmpty else { return [] }
        let selStart = range.location
        let selEnd = range.location + range.length

        var rects: [CGRect] = []
        rects.reserveCapacity(min(lines.count, 4))

        for (i, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineStart + lineRange.length

            let lo = max(selStart, lineStart)
            let hi = min(selEnd, lineEnd)
            guard hi > lo else { continue }

            let xStart = CTLineGetOffsetForStringIndex(line, lo, nil)
            let xEnd = CTLineGetOffsetForStringIndex(line, hi, nil)
            let baseline = lineOrigins[i].y
            let ascent = lineMetrics[i].ascent
            let descent = lineMetrics[i].descent
            rects.append(CGRect(
                x: xStart,
                y: baseline - ascent,
                width: max(0, xEnd - xStart),
                height: ascent + descent))
        }
        return rects
    }

    // MARK: - Draw

    /// Draw into a flipped NSView. `origin` is layout's top-left in view coords.
    func draw(in ctx: CGContext, origin: CGPoint) {
        ctx.saveGState()

        // Inline code backgrounds first — glyphs paint on top.
        if !codeBackgrounds.isEmpty {
            ctx.setFillColor(BlockStyle.inlineCodeBackgroundColor.cgColor)
            for rect in codeBackgrounds {
                // Horizontal padding hugs the glyphs without crowding. The
                // vertical *expansion* (negative inset) is descender
                // coverage: CT's typographic descent is the design metric,
                // but glyphs like `p` / `g` / `y` paint right at that
                // limit, leaving anti-aliased pixels uncovered if the box
                // matches descent exactly. Pulling the box 1pt past on
                // both sides gives clean coverage at the cost of touching
                // adjacent line bgs when consecutive lines both contain
                // inline code — rare enough in chat content to accept.
                let r = rect
                    .offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: -3, dy: -1)
                let path = CGPath(
                    roundedRect: r, cornerWidth: 4, cornerHeight: 4,
                    transform: nil)
                ctx.addPath(path)
            }
            ctx.fillPath()
        }

        // Flip text matrix so Core Text glyphs render upright in a flipped view.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (line, lineOrigin) in zip(lines, lineOrigins) {
            ctx.textPosition = CGPoint(
                x: origin.x + lineOrigin.x,
                y: origin.y + lineOrigin.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}

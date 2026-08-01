import AppKit
import CoreText

/// One attributed string, typeset at one width: the resulting lines, plus the
/// pixel↔index arithmetic over them.
///
/// **Not a `MarkdownBlock`.** It has no decoration, no place in the document, and no
/// margins. It is the piece every line-based block is built out of — paragraphs,
/// headings, code cards, table cells, list markers — so that the typesetting
/// arithmetic exists once instead of once per block kind. `MarkdownTextBlock` is the
/// adapter that turns one of these into a `MarkdownBlock`.
///
/// `@unchecked Sendable` for the reason given on `MarkdownBlock`: `CTLine` and
/// `NSAttributedString` are immutable and thread-safe once created, and nothing
/// here mutates after `make` returns — which is what lets a host typeset off the
/// main actor.
///
/// Coordinates are y-down with the origin at the run's top-left, matching the
/// flipped views this ends up drawn into. Core Text's own line origins are
/// y-up, and that conversion is confined to `make`.
struct MarkdownTextRun: @unchecked Sendable {

    /// One typeset line: the Core Text object, where it sits, and which slice
    /// of the string it covers.
    struct Line: @unchecked Sendable {
        let ctLine: CTLine

        /// Top-left of the line's box, in run-local (y-down) coordinates.
        let origin: CGPoint

        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        /// UTF-16 range into the run's string. Contiguous and gapless across
        /// lines — every character belongs to exactly one line, including the
        /// newline that ended it.
        let range: NSRange

        var height: CGFloat { ascent + descent + leading }

        /// Baseline y in run-local coordinates.
        var baseline: CGFloat { origin.y + ascent }
    }

    let attributed: NSAttributedString
    let lines: [Line]
    let size: CGSize

    /// The width this run was typeset against, which is not `size.width` — that
    /// is the widest line actually produced. Held so a cache can tell "this run
    /// is still valid" from "this run happens to be narrow".
    let typesetWidth: CGFloat

    static let empty = MarkdownTextRun(
        attributed: NSAttributedString(), lines: [], size: .zero, typesetWidth: 0)

    // MARK: - Typesetting

    /// Breaks `attributed` into lines no wider than `width`.
    ///
    /// `CTTypesetter` rather than `CTFramesetter` because the line origins are
    /// ours to place: a framesetter hands back a frame in y-up coordinates whose
    /// origins then have to be un-flipped, and it wants a path sized in advance
    /// — which is the one thing not known yet when the height is what is being
    /// computed.
    static func make(_ attributed: NSAttributedString, width: CGFloat) -> MarkdownTextRun {
        let length = attributed.length
        guard length > 0, width > 0 else { return .empty }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [Line] = []
        var start = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0

        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            // A width too narrow for even one glyph reports a break of zero,
            // which would spin here forever. Force progress and overflow the
            // line instead — a clipped glyph is a better failure than a hang.
            if count <= 0 { count = 1 }

            let range = CFRange(location: start, length: count)
            let ctLine = CTTypesetterCreateLine(typesetter, range)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(
                CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))

            lines.append(
                Line(
                    ctLine: ctLine,
                    origin: CGPoint(x: 0, y: y),
                    ascent: ascent, descent: descent, leading: leading,
                    range: NSRange(location: start, length: count)))

            widest = max(widest, lineWidth)
            y += ascent + descent + leading
            start += count
        }

        return MarkdownTextRun(
            attributed: attributed,
            lines: lines,
            size: CGSize(width: widest, height: y),
            typesetWidth: width)
    }

    // MARK: - Draw

    func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
        guard !lines.isEmpty else { return }

        // The view is flipped, so the context's y grows downward while Core
        // Text's text space grows upward. Flipping the text matrix — rather
        // than the whole CTM — keeps glyphs upright while letting baselines be
        // stated in the same y-down numbers as everything else here.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for line in lines {
            let top = origin.y + line.origin.y
            guard top < dirty.maxY, top + line.height > dirty.minY else { continue }
            ctx.textPosition = CGPoint(x: origin.x + line.origin.x, y: origin.y + line.baseline)
            CTLineDraw(line.ctLine, ctx)
        }

        ctx.restoreGState()
    }

    // MARK: - Selection

    var length: Int { attributed.length }

    /// The index nearest `point`, clamped in both axes: above the first line
    /// resolves to its start, below the last to the run's end, past a line's
    /// right edge to that line's end.
    func index(at point: CGPoint) -> Int {
        guard let line = lineIndex(atY: point.y).map({ lines[$0] }) else { return 0 }
        let local = CGPoint(x: point.x - line.origin.x, y: 0)
        let index = CTLineGetStringIndexForPosition(line.ctLine, local)
        guard index != kCFNotFound else { return line.range.location }
        return min(max(index, line.range.location), NSMaxRange(line.range))
    }

    func rects(from: Int, to: Int) -> [CGRect] {
        let lo = min(from, to)
        let hi = max(from, to)
        guard hi > lo else { return [] }

        return lines.compactMap { line in
            let start = max(lo, line.range.location)
            let end = min(hi, NSMaxRange(line.range))
            guard end > start else { return nil }

            let x1 = CTLineGetOffsetForStringIndex(line.ctLine, start, nil)
            let x2 = CTLineGetOffsetForStringIndex(line.ctLine, end, nil)
            return CGRect(
                x: line.origin.x + min(x1, x2),
                y: line.origin.y,
                width: abs(x2 - x1),
                height: line.height)
        }
    }

    func text(from: Int, to: Int) -> String {
        let lo = max(0, min(from, to))
        let hi = min(length, max(from, to))
        guard hi > lo else { return "" }
        return attributed.attributedSubstring(from: NSRange(location: lo, length: hi - lo)).string
    }

    // MARK: - Lookup

    /// Which line owns `y`, clamped to the first / last. `nil` only when there
    /// are no lines at all.
    private func lineIndex(atY y: CGFloat) -> Int? {
        guard !lines.isEmpty else { return nil }
        if y < 0 { return 0 }

        // Linear rather than binary: a run is one paragraph, and the count is
        // small enough that the search is dominated by the call that reaches
        // it. A code block long enough to change that answer would be the
        // reason to revisit — measure before assuming it is.
        for (index, line) in lines.enumerated() where y < line.origin.y + line.height {
            return index
        }
        return lines.count - 1
    }
}

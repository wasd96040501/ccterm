import AppKit
import CoreText

/// One attributed string, typeset at one width: the resulting lines, plus the
/// pixel↔index arithmetic over them.
///
/// **Not a `MeasuredBlock`.** It has no decoration, no place in the document, and no
/// margins. It is the piece every line-based block is built out of — paragraphs,
/// headings, code cards, table cells, list markers — so that the typesetting
/// arithmetic exists once instead of once per block kind. `MeasuredTextBlock` is the
/// adapter that turns one of these into a `MeasuredBlock`.
///
/// Produced by `ShapedText.typeset(width:)`, never constructed from a string
/// directly: the shaping this is broken out of is width-independent and belongs
/// to the recipe, so the only way to get one is to ask text that has already been
/// shaped.
///
/// `@unchecked Sendable` for the reason given on `MeasuredBlock`: `CTLine` and
/// `NSAttributedString` are immutable and thread-safe once created, and nothing
/// here mutates after `make` returns — which is what lets a host typeset off the
/// main actor.
///
/// Coordinates are y-down with the origin at the text's top-left, matching the
/// flipped views this ends up drawn into. Core Text's own line origins are
/// y-up, and that conversion is confined to `make`.
struct TypesetText: @unchecked Sendable {

    /// One typeset line: the Core Text object, where it sits, and which slice
    /// of the string it covers.
    struct Line: @unchecked Sendable {
        let ctLine: CTLine

        /// Top-left of the line's box, in text-local (y-down) coordinates.
        let origin: CGPoint

        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        /// UTF-16 range into the text's string. Contiguous and gapless across
        /// lines — every character belongs to exactly one line, including the
        /// newline that ended it.
        let range: NSRange

        var height: CGFloat { ascent + descent + leading }

        /// Baseline y in text-local coordinates.
        var baseline: CGFloat { origin.y + ascent }
    }

    /// One inline symbol, and where it landed. Not part of `Line` because a
    /// symbol is a property of the *text* rather than of the line that happened
    /// to catch it — and because drawing them after every line is what keeps them
    /// out of the text matrix Core Text needs flipped.
    struct Symbol: @unchecked Sendable {
        let symbol: InlineSymbol

        /// The box the glyph is fitted into, in text-local (y-down) coordinates.
        let rect: CGRect
    }

    let attributed: NSAttributedString
    let lines: [Line]
    let symbols: [Symbol]
    let size: CGSize

    /// The width this text was typeset against, which is not `size.width` — that
    /// is the widest line actually produced. Held so a cache can tell "this text
    /// is still valid" from "this text happens to be narrow".
    let typesetWidth: CGFloat

    static let empty = TypesetText(
        attributed: NSAttributedString(), lines: [], symbols: [], size: .zero, typesetWidth: 0)

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

        // After the glyphs, and outside the flipped text matrix: an image is
        // placed by a rectangle rather than by a baseline, so it wants the same
        // y-down space every other rectangle here is stated in.
        for placement in symbols {
            let rect = placement.rect.offsetBy(dx: origin.x, dy: origin.y)
            guard rect.minY < dirty.maxY, rect.maxY > dirty.minY else { continue }
            placement.symbol.draw(in: rect, into: ctx)
        }
    }

    // MARK: - Selection

    var length: Int { attributed.length }

    /// The index nearest `point`, clamped in both axes: above the first line
    /// resolves to its start, below the last to the text's end, past a line's
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

    /// An inline symbol occupies a real character, so a drag across one picks it
    /// up; it is dropped here rather than at the drag, because the index space
    /// has to stay a function of the string for the endpoints to survive a
    /// re-measure. What reaches the pasteboard is the text a reader can see.
    func text(from: Int, to: Int) -> String {
        let lo = max(0, min(from, to))
        let hi = min(length, max(from, to))
        guard hi > lo else { return "" }
        let slice = attributed.attributedSubstring(from: NSRange(location: lo, length: hi - lo))
        guard !symbols.isEmpty else { return slice.string }
        return slice.string.filter { $0 != InlineSymbol.placeholder }
    }

    /// The link under `point`, or `nil`.
    ///
    /// Two steps, and the second is the one that matters. `index(at:)` clamps —
    /// a point past the end of a line resolves to that line's last character, a
    /// point below the text to its end — so an attribute lookup on its own would
    /// report a link for the empty space to the right of one. The index is
    /// trusted only once the point is confirmed to be inside a rectangle the run
    /// actually occupies, which is the same `rects(from:to:)` a selection draws.
    func link(at point: CGPoint) -> InlineLink? {
        guard !lines.isEmpty, length > 0, let index = characterIndex(at: point) else { return nil }

        var range = NSRange()
        guard let url = attributed.attribute(.link, at: index, effectiveRange: &range) as? URL,
            rects(from: range.location, to: NSMaxRange(range))
                .contains(where: { $0.contains(point) })
        else { return nil }

        return InlineLink(url: url)
    }

    /// The index of the character the point is **inside**, rather than the
    /// insertion point nearest it.
    ///
    /// `index(at:)` answers the caret's question — a click in the right half of a
    /// glyph puts the caret after it — and that is right for selection and wrong
    /// for "what am I pointing at". The difference is invisible on a run of
    /// several characters and total on a run of one: a footnote's superscript is
    /// a single digit, and the caret index for a point anywhere past its middle
    /// is the character *after* it, which carries none of its attributes.
    private func characterIndex(at point: CGPoint) -> Int? {
        guard let line = lineIndex(atY: point.y).map({ lines[$0] }) else { return nil }

        let x = point.x - line.origin.x
        let caret = CTLineGetStringIndexForPosition(line.ctLine, CGPoint(x: x, y: 0))
        guard caret != kCFNotFound else { return nil }

        var index = min(max(caret, line.range.location), NSMaxRange(line.range))
        if index > line.range.location, CTLineGetOffsetForStringIndex(line.ctLine, index, nil) > x {
            index -= 1
        }
        return min(index, length - 1)
    }

    // MARK: - Lookup

    /// Which line owns `y`, clamped to the first / last. `nil` only when there
    /// are no lines at all.
    private func lineIndex(atY y: CGFloat) -> Int? {
        guard !lines.isEmpty else { return nil }
        if y < 0 { return 0 }

        // Linear rather than binary: one of these is one paragraph, and the count is
        // small enough that the search is dominated by the call that reaches
        // it. A code block long enough to change that answer would be the
        // reason to revisit — measure before assuming it is.
        for (index, line) in lines.enumerated() where y < line.origin.y + line.height {
            return index
        }
        return lines.count - 1
    }
}

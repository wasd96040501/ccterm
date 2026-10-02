import AppKit
import CoreText

/// Text that has been shaped but not yet broken into lines.
///
/// The recipe half of `TypesetText`, and the reason the split is worth
/// having: **shaping does not depend on width.** `CTTypesetterCreateWithAttributedString`
/// does the expensive part — attribute itemisation, font matching and fallback,
/// bidi analysis, glyph generation — and the only call that takes a width is
/// `CTTypesetterSuggestLineBreak`, which walks advances that are already
/// resolved. Holding the typesetter here means a window resize re-breaks lines
/// without re-shaping a single glyph.
///
/// So this is what a `Block` stores and `measure` consumes. A block that builds
/// one of these inside `measure` is doing width-independent work on the
/// width-dependent path, which is the thing that boundary exists to prevent.
///
/// `@unchecked Sendable` for the reason given on `MeasuredBlock`: `CTTypesetter`
/// and `NSAttributedString` are immutable and thread-safe once created, and
/// nothing here mutates after `init`.
struct ShapedText: @unchecked Sendable {

    let attributed: NSAttributedString

    /// `nil` for empty text, which has nothing to shape and no lines to produce.
    private let typesetter: CTTypesetter?

    init(_ attributed: NSAttributedString) {
        self.attributed = attributed
        self.typesetter =
            attributed.length > 0 ? CTTypesetterCreateWithAttributedString(attributed) : nil
    }

    init(_ string: String, attributes: [NSAttributedString.Key: Any]) {
        self.init(NSAttributedString(string: string, attributes: attributes))
    }

    static let empty = ShapedText(NSAttributedString())

    var isEmpty: Bool { typesetter == nil }

    // MARK: - Line breaking

    /// Breaks the text into lines no wider than `width`, and no more than `limit`
    /// of them.
    ///
    /// `CTTypesetter` rather than `CTFramesetter` because the line origins are
    /// ours to place: a framesetter hands back a frame in y-up coordinates whose
    /// origins then have to be un-flipped, and it wants a path sized in advance
    /// — which is the one thing not known yet when the height is what is being
    /// computed.
    ///
    /// ## The limit
    ///
    /// **Truncation belongs here and nowhere above.** How many lines a string
    /// takes is a fact about a *width* — the same message is three lines in a
    /// wide window and seven in a narrow one — so a caller that cut the string
    /// short before this point would be answering a question it cannot have
    /// asked yet, and would be cutting the very characters a copy is taken from.
    /// This is also the one place that already knows what a line is.
    ///
    /// The last line the limit allows is built over the **whole** remainder and
    /// then truncated with `CTLineCreateTruncatedLine`, so the ellipsis lands
    /// where Core Text says it fits rather than where arithmetic guesses. Its
    /// `range` covers that whole remainder, which is Apple's documented behaviour
    /// and has one consequence worth knowing: a drag onto the last line can copy
    /// text that is not on screen. Left that way deliberately — for a message the
    /// reader typed, "copy what I sent" is the right answer, and clamping it
    /// would mean deriving where the ellipsis cut, which Core Text does not
    /// report.
    ///
    /// **Inline symbols in the hidden tail are not placed.** A symbol is placed
    /// by asking the line for the pen at its index, and every index in the hidden
    /// tail reports the truncation point — so on a truncated line a symbol whose
    /// next position has the same pen is skipped, rather than drawn on top of the
    /// ellipsis (`UserMessageTokenTests.testAPictureGlyphInTheHiddenTailIsNotDrawn`).
    ///
    /// ## The exclusion
    ///
    /// A rectangle, in the text's own coordinates, that no glyph may enter —
    /// `NSTextContainer.exclusionPaths`, cut down to the one shape anything here
    /// needs: a box hung off the trailing edge, like a code card's language chip.
    /// A line whose box meets it and whose ink would reach it is broken again at
    /// the exclusion's leading edge, and the rest flows on to the next line.
    ///
    /// Every other line is broken exactly as it would be without one, and a line
    /// that stops short of the box keeps its full width — so text that never
    /// reaches the chip costs nothing, not even a narrower first line. Only the
    /// lines that could meet it pay one extra `CTLine`, to learn how tall they are
    /// before deciding.
    func typeset(
        width: CGFloat, limit: Int = .max, excluding exclusion: CGRect? = nil
    )
        -> TypesetText
    {
        guard let typesetter, width > 0, limit > 0 else { return .empty }
        let length = attributed.length

        var lines: [TypesetText.Line] = []
        var symbols: [TypesetText.Symbol] = []
        var start = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0
        var isTruncated = false

        func suggestedBreak(from start: Int, width: CGFloat) -> Int {
            // A width too narrow for even one glyph reports a break of zero,
            // which would spin here forever. Force progress and overflow the
            // line instead — a clipped glyph is a better failure than a hang.
            max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
        }

        while start < length {
            var breakWidth = width
            var count = suggestedBreak(from: start, width: width)

            if let exclusion, exclusion.minX > 0, exclusion.minX < width, y < exclusion.maxY {
                let probe = CTTypesetterCreateLine(
                    typesetter, CFRange(location: start, length: count))
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                // Ink, not advance: trailing spaces — and the newline that ends
                // every line of a code block — reach nothing.
                let ink =
                    CGFloat(CTLineGetTypographicBounds(probe, &ascent, &descent, &leading))
                    - CGFloat(CTLineGetTrailingWhitespaceWidth(probe))
                if y + ascent + descent + leading > exclusion.minY, ink > exclusion.minX {
                    breakWidth = exclusion.minX
                    count = suggestedBreak(from: start, width: breakWidth)
                }
            }

            // The last line allowed, with text still to come after it.
            isTruncated = lines.count == limit - 1 && start + count < length
            if isTruncated { count = length - start }

            let full = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            let ctLine =
                isTruncated
                ? CTLineCreateTruncatedLine(full, Double(breakWidth), .end, ellipsis(at: start))
                    ?? full
                : full

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(
                CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))

            let range = NSRange(location: start, length: count)
            lines.append(
                TypesetText.Line(
                    ctLine: ctLine,
                    origin: CGPoint(x: 0, y: y),
                    ascent: ascent, descent: descent, leading: leading,
                    range: range))

            // Where each inline symbol landed, settled here because it is
            // width-dependent — the same reason line origins are settled here and
            // not on the recipe. Asking Core Text once per symbol, on the line
            // that owns it, rather than re-deriving it on every repaint.
            attributed.enumerateAttribute(.inlineSymbol, in: range) { value, at, _ in
                guard let symbol = value as? InlineSymbol else { return }
                let pen = CTLineGetOffsetForStringIndex(ctLine, at.location, nil)
                // On a truncated line every position of the hidden tail reports
                // the ellipsis's pen, so a symbol there takes no room: it is not
                // on screen, and drawing it would land on the ellipsis.
                if isTruncated,
                    CTLineGetOffsetForStringIndex(ctLine, at.location + 1, nil) - pen < symbol.inkWidth / 2
                {
                    return
                }
                symbols.append(
                    TypesetText.Symbol(
                        symbol: symbol,
                        // The pen and the baseline are all this knows; where the
                        // artwork goes relative to them is the symbol's own
                        // arithmetic.
                        rect: symbol.frame(pen: pen, baseline: y + ascent)))
            }

            widest = max(widest, lineWidth)
            y += ascent + descent + leading
            start += count
            if isTruncated { break }
        }

        return TypesetText(
            attributed: attributed,
            lines: lines,
            symbols: symbols,
            size: CGSize(width: widest, height: y),
            typesetWidth: width,
            isTruncated: isTruncated)
    }

    /// The "…" spliced onto a truncated line, wearing the face and colour the
    /// text has where it was cut — so the ellipsis reads as part of the sentence
    /// rather than as something added to it.
    ///
    /// Anything that would make the token more than a glyph is dropped: a run
    /// delegate reserves an advance for artwork that is not in the token, and the
    /// symbol attribute names artwork nobody will place.
    private func ellipsis(at index: Int) -> CTLine {
        var attributes = attributed.attributes(
            at: min(index, attributed.length - 1), effectiveRange: nil)
        attributes[kCTRunDelegateAttributeName as NSAttributedString.Key] = nil
        attributes[.inlineSymbol] = nil
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: attributes) as CFAttributedString)
    }

    // MARK: - Intrinsic widths

    /// The two numbers CSS calls `min-content` and `max-content`: the width the
    /// text settles at when broken as hard as it can be — Latin per word, CJK per
    /// glyph — and the width it wants with no wrapping at all.
    ///
    /// Both are properties of the text, not of any width it might be placed in,
    /// so they belong to whoever composes a `TableBlock` rather than to its `measure`.
    /// Computed on demand because only column sizing needs them: paying the
    /// narrow pass for every paragraph in a document would cost more than it
    /// saves.
    func intrinsicWidths() -> (min: CGFloat, max: CGFloat) {
        (min: typeset(width: 1).size.width, max: typeset(width: .greatestFiniteMagnitude).size.width)
    }
}

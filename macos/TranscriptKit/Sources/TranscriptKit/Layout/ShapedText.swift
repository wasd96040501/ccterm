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

    /// Breaks the text into lines no wider than `width`.
    ///
    /// `CTTypesetter` rather than `CTFramesetter` because the line origins are
    /// ours to place: a framesetter hands back a frame in y-up coordinates whose
    /// origins then have to be un-flipped, and it wants a path sized in advance
    /// — which is the one thing not known yet when the height is what is being
    /// computed.
    func typeset(width: CGFloat) -> TypesetText {
        guard let typesetter, width > 0 else { return .empty }
        let length = attributed.length

        var lines: [TypesetText.Line] = []
        var symbols: [TypesetText.Symbol] = []
        var start = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0

        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            // A width too narrow for even one glyph reports a break of zero,
            // which would spin here forever. Force progress and overflow the
            // line instead — a clipped glyph is a better failure than a hang.
            if count <= 0 { count = 1 }

            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))

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
                symbols.append(
                    TypesetText.Symbol(
                        symbol: symbol,
                        // The pen and the baseline are all this knows; where the
                        // artwork goes relative to them is the symbol's own
                        // arithmetic.
                        rect: symbol.frame(
                            pen: CTLineGetOffsetForStringIndex(ctLine, at.location, nil),
                            baseline: y + ascent)))
            }

            widest = max(widest, lineWidth)
            y += ascent + descent + leading
            start += count
        }

        return TypesetText(
            attributed: attributed,
            lines: lines,
            symbols: symbols,
            size: CGSize(width: widest, height: y),
            typesetWidth: width)
    }

    // MARK: - Intrinsic widths

    /// The two numbers CSS calls `min-content` and `max-content`: the width the
    /// text settles at when broken as hard as it can be — Latin per word, CJK per
    /// glyph — and the width it wants with no wrapping at all.
    ///
    /// Both are properties of the text, not of any width it might be placed in,
    /// so they belong to whoever composes a `Table` rather than to its `measure`.
    /// Computed on demand because only column sizing needs them: paying the
    /// narrow pass for every paragraph in a document would cost more than it
    /// saves.
    func intrinsicWidths() -> (min: CGFloat, max: CGFloat) {
        (min: typeset(width: 1).size.width, max: typeset(width: .greatestFiniteMagnitude).size.width)
    }
}

import AppKit

/// What the reader typed, on a bubble against the right edge — cut short, with a
/// way to ask for the rest, when it runs long.
///
/// **Plain text, deliberately.** What a user types is what gets sent, and a
/// markdown pass would render `Sources/**/*.swift`, `__init__` and `# 3` as
/// something other than what left the field — the one row in a transcript where
/// the source and the display have to agree character for character. The app's
/// previous renderer took the same position in the same words: "user input is raw
/// text, markdown emphasis is not parsed here (that's an assistant-content
/// concern)". It is also what keeps the line cap below cheap: capping one
/// `TypesetText`'s lines is arithmetic, where capping a tree of blocks would be a
/// height budget every block kind had to know how to answer.
///
/// Structurally this is `CodeBlock` — a rounded fill, padding, text inside — with
/// two differences worth reading for:
///
/// **It hugs, and that costs nothing.** `TypesetText.size.width` is the widest
/// line's ink, where `MeasuredBlock.size.width` is the width the block was
/// measured *into*; the bubble's rectangle comes from the first, the row's size
/// from the second. So one typeset pass at the cap gives both the line breaks and
/// the width to draw the fill at, and the glyphs — already laid out left-aligned
/// from x = 0 — do not move when the fill shrinks around them.
///
/// **The cap is a fraction, not a constant.** The renderer this replaces used two
/// rules at once (a 560pt ceiling *and* a 60pt minimum left gutter) because
/// neither alone survives both ends of the window's range. One fraction of the
/// content column does: it leaves a quarter of the column as gutter at every
/// width, and needs no second rule to keep a narrow window from letting the bubble
/// span the whole thing.
///
/// A bubble that wrapped an arbitrary `Block` — markdown inside, a code card
/// inside — would be the more general shape, and it is not this one for a reason:
/// hugging needs the content's ink width, and `MeasuredBlock` guarantees the
/// opposite (`size.width` is always the measured width). Getting it would mean a
/// max-content member on the protocol and an implementation in every block kind.
/// The day something needs markdown in a bubble is the day to weigh that; until
/// then this holds a `ShapedText`.
///
/// ## More
///
/// Past `collapseAfterLines` the message is cut and a run reading `↗ More` sits
/// under it. Three decisions in that sentence:
///
/// - **It is a line of its own, not a tail on the last one.** Sharing the line
///   with the ellipsis is what forced the previous renderer to shrink its
///   truncation width by a constant so the "…" would not crowd the affordance —
///   a number that existed only to keep two decorations apart. A line of its own
///   has nothing to avoid.
/// - **It is styled as a link and *is* one**, in the only sense this package has:
///   `link(at:)` answers for it, so the band, the pointing hand and the
///   press-is-a-click rule are `BlockView`'s existing ones rather than a second
///   copy. What it lacks is an address, which is `InlineLink.Destination`.
/// - **It occupies one reserved position** in the index space, the way `Table`
///   reserves one per cell — an affordance is a place the pointer can be, and
///   `MeasuredBlock.length` documents exactly this. It contributes no characters,
///   so copying a whole bubble copies the message and not the word "More".
struct UserMessage: Block, @unchecked Sendable {

    let text: ShapedText

    /// The affordance's own run: the glyph, a space's worth of gap that the
    /// symbol carries itself, and the word. Shaped here rather than in `measure`
    /// for the reason the split exists — none of it depends on a width.
    private let more: ShapedText

    /// How much of the content column the bubble may occupy. The remainder is
    /// gutter — the empty space on the left that makes the row read as one side
    /// of a conversation rather than as another paragraph.
    var maxWidthFraction: CGFloat = 0.75

    var horizontalPadding: CGFloat = 16

    /// Matched to `cornerRadius` on purpose: at a radius wider than the padding
    /// the corner's curve cuts into the first and last lines' glyphs, and at
    /// equality it sits flush with the text's own margin.
    var verticalPadding: CGFloat = 14

    /// The "soft" tier — a speech balloon, where a code card's 6 is the
    /// structural one. Rounder reads as personal; tighter reads as data.
    var cornerRadius: CGFloat = 14

    /// The accent at 15%, so the bubble follows both the reader's chosen accent
    /// and the light/dark flip without a second colour being stated for either.
    var backgroundColor: NSColor = .controlAccentColor.withAlphaComponent(0.15)

    /// How many lines survive the cut.
    var collapseAfterLines: Int = 12

    /// And how many have to be hidden for cutting to be worth it. A "More" that
    /// reveals two lines is worse than the two lines, so a message only a little
    /// over the limit is shown whole — the cut starts at
    /// `collapseAfterLines + minHiddenLines` lines.
    var minHiddenLines: Int = 3

    /// Between the last line of the message and the affordance under it. Half the
    /// gap between two paragraphs: it separates the run from the text without
    /// letting it drift away from the message it belongs to.
    var moreTopGap: CGFloat = 6

    init(_ text: ShapedText, style: MarkdownStyle = .default) {
        self.text = text
        self.more = Self.moreRun(style: style)
    }

    /// The body face and colour come from `MarkdownStyle` because that is where
    /// prose gets them, and a user's turn is set at the same size as the answer
    /// under it — two constants for one size would drift apart.
    init(_ source: String, style: MarkdownStyle = .default) {
        self.init(
            ShapedText(
                source,
                attributes: [.font: style.bodyFont, .foregroundColor: style.textColor]),
            style: style)
    }

    /// `↗ More`, built the way `MarkdownInlineBuilder` builds a link: the glyph
    /// in front, the label in the link colour, and the gap between them part of
    /// the symbol's advance rather than a space in the string.
    private static func moreRun(style: MarkdownStyle) -> ShapedText {
        let run = NSMutableAttributedString(
            attributedString: InlineSymbol(
                .more, font: style.bodyFont, color: style.linkColor
            ).attributedString(font: style.bodyFont))
        run.append(
            NSAttributedString(
                string: String(localized: "More", bundle: .module),
                attributes: [.font: style.bodyFont, .foregroundColor: style.linkColor]))
        return ShapedText(run)
    }

    func measure(_ width: CGFloat) -> MeasuredBlock {
        let column = width * maxWidthFraction
        // Not clamped to a positive minimum, unlike `CodeBlock`'s: a column with
        // no room left inside its padding has nothing to show, and `typeset`
        // already answers that with no lines at all. Clamping to 1 would instead
        // break every character onto its own line — which is what a host that
        // loads before laying out (see `reloadData()`) would pay for.
        let inner = column - horizontalPadding * 2

        // Broken against the limit that decides *whether* to cut, so the common
        // case — a message that fits — is one pass and the answer is already the
        // one to draw. Only a message that overruns pays for the second pass, and
        // only that pass knows the shape the reader ends up seeing.
        var text = self.text.typeset(width: inner, limit: collapseAfterLines + minHiddenLines)
        var more: Measured.More?
        if text.isTruncated {
            text = self.text.typeset(width: inner, limit: collapseAfterLines)
            more = Measured.More(
                text: self.more.typeset(width: inner),
                origin: CGPoint(x: 0, y: text.size.height + moreTopGap))
        }

        let inkWidth = max(text.size.width, more?.text.size.width ?? 0)
        let contentHeight = (more.map { $0.origin.y + $0.text.size.height }) ?? text.size.height

        let bubbleWidth = min(column, inkWidth + horizontalPadding * 2)
        let bubble = CGRect(
            x: width - bubbleWidth,
            y: 0,
            width: bubbleWidth,
            height: contentHeight + verticalPadding * 2)
        let textOrigin = CGPoint(x: bubble.minX + horizontalPadding, y: verticalPadding)

        return Measured(
            text: text,
            textOrigin: textOrigin,
            // The row is the full width whatever the bubble came out at — that is
            // `MeasuredBlock`'s invariant, and it is also what keeps the gutter
            // part of the row rather than something the transcript has to add.
            size: CGSize(width: width, height: bubble.height),
            bubble: bubble,
            cornerRadius: cornerRadius,
            backgroundColor: backgroundColor,
            // Placed relative to the text it follows, then lifted into the row's
            // space once — the same two steps every other origin here takes.
            more: more.map {
                Measured.More(
                    text: $0.text,
                    origin: CGPoint(x: textOrigin.x, y: textOrigin.y + $0.origin.y))
            })
    }

    /// A `MeasuredTextBlock`, so the message's own selection is the inherited
    /// implementation — the bubble is decoration, and `textOrigin` is the whole of
    /// what the defaults need to translate between the row's space and the text's.
    ///
    /// The four members that are written out are the four the affordance changes:
    /// it holds a position, it can be pointed at, it is a link, and it highlights.
    struct Measured: MeasuredTextBlock, @unchecked Sendable {

        /// The `↗ More` run and where it sits, in the row's coordinates.
        struct More: @unchecked Sendable {
            let text: TypesetText
            let origin: CGPoint

            /// What the pointer has to be inside, and what the hover band covers.
            /// The typeset size is the run's ink, so this hugs the glyphs rather
            /// than spanning the bubble.
            var frame: CGRect { CGRect(origin: origin, size: text.size) }
        }

        let text: TypesetText
        let textOrigin: CGPoint
        let size: CGSize

        /// The fill, in block-local coordinates. Right-aligned and no wider than
        /// its glyphs need.
        let bubble: CGRect

        let cornerRadius: CGFloat
        let backgroundColor: NSColor

        /// `nil` when the whole message is on screen, which is the common case.
        let more: More?

        /// The affordance's reserved position: one past the message's own text.
        private var moreIndex: Int { text.length }

        /// One more than the message when there is something to press. See the
        /// note on `MeasuredBlock.length` — positions, not characters.
        var length: Int { text.length + (more == nil ? 0 : 1) }

        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            list.append(
                .fill(
                    roundedRect: bubble.offsetBy(dx: origin.x, dy: origin.y),
                    radius: cornerRadius, backgroundColor))
            list.append(
                .text(text, at: CGPoint(x: origin.x + textOrigin.x, y: origin.y + textOrigin.y)))
            guard let more else { return }
            list.append(
                .text(
                    more.text,
                    at: CGPoint(x: origin.x + more.origin.x, y: origin.y + more.origin.y)))
        }

        // MARK: - The affordance is a link

        func link(at index: Int) -> InlineLink? {
            guard more != nil, index == moreIndex else { return text.link(at: index) }
            return InlineLink(destination: .more, range: moreIndex..<(moreIndex + 1))
        }

        /// Declines everywhere the message's own text declines, and answers the
        /// reserved position over the affordance's glyphs — which is what makes
        /// `link(at: point)`, and therefore the cursor and the click, find it.
        func characterIndex(at point: CGPoint) -> Int? {
            if let more, more.frame.contains(point) { return moreIndex }
            return text.characterIndex(
                at: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y))
        }

        /// The message's own rectangles, plus the affordance's when the range
        /// covers its position.
        ///
        /// This is what draws the hover band — `BlockView` asks for the
        /// rectangles over the link's range and knows nothing else about it — and
        /// it is also why selecting the whole bubble highlights the affordance the
        /// way selecting a paragraph highlights the links in it.
        func rects(from: Int, to: Int) -> [CGRect] {
            var rects = text.rects(from: from, to: to)
                .map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
            if let more, min(from, to) <= moreIndex, max(from, to) > moreIndex {
                rects.append(more.frame)
            }
            return rects
        }
    }
}

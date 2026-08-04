import AppKit

/// A measured block: fixed size, ready to draw, ready to select in.
///
/// The product of `Block.measure(_:)`, and the half of the pair that has a
/// width. `size.width` is **always the width it was measured into**, never the
/// extent of its ink — a three-word paragraph in a 700-point column reports 700.
/// That invariant is what makes "is this tree still valid at the current content
/// width" a single comparison rather than something nobody can ask.
///
/// `size.height` likewise covers everything the block occupies, including any
/// breathing room it gave itself. A block's box is the whole of what it takes;
/// none of its spacing is left for a parent to add.
///
/// Everything is in the block's **own coordinate space** — origin at its
/// top-left, y growing downward. A block never knows where it sits; its parent
/// offsets whatever comes back.
///
/// ## Sendable
///
/// Measuring is pure and thread-safe, so a host may do it off the main actor and
/// hand the result over. Every conformer is `@unchecked Sendable` for the same
/// reason: they hold `CTLine`, `NSAttributedString`, `NSFont` and `NSColor`,
/// none of which Swift knows to be safe, and all of which are immutable once
/// created and documented thread-safe. Nothing here is mutated after `measure`
/// returns — that is the property the `unchecked` rests on, and the one to
/// preserve.
///
/// ## The selection model
///
/// Every block linearises its content into a flat index space `0..<length`,
/// which the parent uses for exactly one thing: **ordering**. Who comes before
/// whom, what lies between two points, how to stitch two blocks' text together.
///
/// It deliberately does *not* use that space to decide **shape**. Hence
/// `rects(from:to:)` takes two endpoints rather than a `Range` — a `Range` has
/// already asserted that everything between its bounds is selected, which is the
/// linear assumption, and a table's selection is a rectangle. Handing over the
/// endpoints leaves the block that owns them free to decide what lies between,
/// and keeps the decoding of its own index space private.
///
/// Two default paths cover nearly everything: `MeasuredTextBlock` for "I am a stack of
/// typeset lines", and `BlockStack.Measured` for "I hold other blocks".
protocol MeasuredBlock: Sendable {

    /// The measured size. `width` is the width this block was measured into;
    /// `height` is everything it occupies.
    var size: CGSize { get }

    /// Describes what this block paints, with its top-left at `origin`, in the
    /// target view's (flipped, y-down) coordinates.
    ///
    /// Appends to a list the **caller** owns — nothing here is stored, and a
    /// block stays as immutable after `paint` as it was before. What each item
    /// carries is a phase, so where it lands is decided by that number rather
    /// than by when this method happened to run. See `PaintItem`.
    ///
    /// `dirty` is in the same space, and is permission to skip rather than a
    /// clip — the context is already clipped when the list is played. A container
    /// uses it to avoid walking children that cannot be seen, which is what keeps
    /// a row holding a two-thousand-line code block affordable to scroll past.
    func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem])

    /// How many positions this block occupies in its parent's flat index space.
    ///
    /// **Positions, not characters.** The two coincide in a paragraph and are not
    /// required to: a container that stitches its children's text together with a
    /// separator may reserve a position for it, which is what lets an empty child
    /// still be somewhere a selection can start. `Table` does reserve one and
    /// `BlockStack` does not, each for a reason written where it packs — an empty
    /// cell is a place, a thematic break is not.
    ///
    /// What the contract fixes is only this: every index in `0..<length` decodes
    /// to exactly one place in this block, and a block agrees with itself about
    /// where that place is — point at something, take the index back, and the
    /// geometry that index reports contains the point. `IndexRoundTripTests` is
    /// what holds it, and it is the test a wrong `base` in a container fails.
    ///
    /// Note what that does *not* claim: that every position is pointable. A
    /// reserved separator has no glyph, so no point resolves to it — which is why
    /// the property above is stated over points rather than over `0..<length`.
    ///
    /// Content that cannot be selected contributes nothing: a list marker, a
    /// task checkbox, a rule, an image. They are drawn, not indexed.
    var length: Int { get }

    /// The index nearest `point`, in block-local coordinates.
    ///
    /// Non-optional on purpose. A click can land in padding, in the gap between
    /// two blocks, or past the end of a line, and every one of those has to
    /// resolve to a position — the caller knows less about where the content is
    /// than the block does, so pushing the choice up would put it in the hands
    /// of the party least able to make it. Clamp instead.
    func index(at point: CGPoint) -> Int

    /// The highlight rectangles for a selection running between two indices, in
    /// block-local coordinates. The endpoints arrive unordered — a drag runs in
    /// either direction.
    func rects(from: Int, to: Int) -> [CGRect]

    /// The plain text a selection between two indices copies as.
    func text(from: Int, to: Int) -> String

    /// The word under `point` — what a double-click takes.
    ///
    /// Where the boundaries are is not this package's business to decide:
    /// `NSAttributedString.doubleClick(at:)` is what `NSTextView` asks, and it
    /// knows about locales, CJK, hyphens and apostrophes.
    ///
    /// **A point rather than an index**, which is the one place the index space
    /// is not enough. Line ranges are gapless, so the end of one line and the
    /// start of the next are the same integer; a click in the blank to the right
    /// of a line resolves to that integer, and the word *at* it belongs to the
    /// line below. Only the click knows which side of the boundary it was on.
    ///
    /// Nor can `index(at:)` settle it on this method's behalf: the same
    /// boundary value is what a **drag** to that spot needs, so that ending one
    /// past the right edge of a line selects through the end of it. `NSTextView`
    /// answers this by carrying an affinity alongside the index; taking the
    /// point keeps the same information without a second field on every endpoint
    /// a selection stores. See `TypesetText`'s § Units for the full argument.
    func wordRange(at point: CGPoint) -> Range<Int>

    /// The character the pointer is **inside**, in block-local coordinates, or
    /// `nil` when it is inside none.
    ///
    /// The pointing question, where `index(at:)` is the caret's. It declines
    /// rather than clamps: the gap a short last line leaves, the padding around a
    /// table's cells, the space past the end of a line are all places a caret has
    /// to go somewhere and a pointer is on nothing. Keeping the two apart is what
    /// stops a click to the right of a link from opening it — and it is why
    /// `link(at:)` below has no geometry left to re-check.
    func characterIndex(at point: CGPoint) -> Int?

    /// The link covering `index`, or `nil`.
    ///
    /// The third member of the family `wordRange(at:)` and `paragraphRange(at:)`
    /// belong to — *which positions does the thing containing this index cover* —
    /// differing only in that a link may not be there, and that it carries a
    /// destination alongside its range.
    ///
    /// It takes an index rather than a point because a query that **locates**
    /// something has to hand back the location. The version this replaces returned
    /// a bare destination from a point, which left every caller holding a link it
    /// could not address, and made this the one member of the protocol with
    /// nothing to translate — it looked like it obeyed the rules only because it
    /// had discarded the thing the rules are about.
    ///
    /// No default implementation on purpose, here or on `characterIndex(at:)`. A
    /// container that forgets to forward either would not fail — its links would
    /// simply stop responding, which is exactly the kind of quiet loss the closed
    /// enums elsewhere here exist to prevent. Two protocols supply both for free
    /// (`MeasuredTextBlock` looks the attribute up, `MeasuredOpaqueBlock` has
    /// nothing to find), so what is left to write is the containers, where the
    /// offset and the lift are the whole of the work.
    func link(at index: Int) -> InlineLink?

    /// The paragraph under `point` — what a triple-click takes.
    ///
    /// A *paragraph*, not a visual line, so wrapping never splits one. In
    /// verbatim text that comes out as one logical line, because the separator
    /// there is a real newline; in prose a hard break does not end one, which is
    /// what a browser does with a `<br>` inside a `<p>`. Both fall out of
    /// `NSString.paragraphRange(for:)` without a branch.
    ///
    /// Takes a point for the reason given on `wordRange(at:)`.
    func paragraphRange(at point: CGPoint) -> Range<Int>
}

extension MeasuredBlock {

    /// The whole block selected.
    func fullRects() -> [CGRect] { rects(from: 0, to: length) }

    /// The link under `point`, in block-local coordinates, or `nil`.
    ///
    /// Written **once**, here, rather than once per container — which is most of
    /// what the split bought. Both halves are members every container already has
    /// to implement, and how they compose is not a decision any container gets to
    /// make differently.
    func link(at point: CGPoint) -> InlineLink? {
        characterIndex(at: point).flatMap { link(at: $0) }
    }
}

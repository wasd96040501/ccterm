import AppKit

/// A measured layout: fixed size, ready to draw, ready to select in.
///
/// The product of `Layout.measure(_:)`, and the half of the pair that has a
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
/// Two default paths cover nearly everything: `MarkdownTextBlock` for "I am a stack of
/// typeset lines", and `BlockStack.Measured` for "I hold other blocks".
protocol MarkdownBlock: Sendable {

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
}

extension MarkdownBlock {

    /// The whole block selected.
    func fullRects() -> [CGRect] { rects(from: 0, to: length) }
}

/// A block with no selectable content — a rule, an image, a decoration. Draws,
/// indexes to nothing, copies as nothing.
///
/// A protocol rather than four empty methods repeated per type, so that "this
/// one is not selectable" is a declaration at the conformance rather than
/// something a reader infers from four empty bodies.
protocol MarkdownOpaqueBlock: MarkdownBlock {}

extension MarkdownOpaqueBlock {
    var length: Int { 0 }
    func index(at point: CGPoint) -> Int { 0 }
    func rects(from: Int, to: Int) -> [CGRect] { [] }
    func text(from: Int, to: Int) -> String { "" }
}

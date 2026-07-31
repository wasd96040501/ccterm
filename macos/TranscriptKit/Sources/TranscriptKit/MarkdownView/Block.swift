import AppKit

/// One unit of drawable, selectable content inside a self-drawn row.
///
/// A block is an **already-laid-out value**, not a recipe: it was built against
/// a specific width and holds the typeset result, so `size` is a stored answer
/// rather than a computation. A width change rebuilds the tree; it does not
/// re-measure this one. That is what makes measuring a row (`size.height`) free
/// after the build, which matters because the transcript sizes its scroller by
/// summing *every* row, on screen or not.
///
/// Everything is expressed in the block's **own coordinate space** — origin at
/// its top-left, y growing downward. A block never knows where it sits in the
/// document; its parent offsets whatever comes back.
///
/// ## The selection model
///
/// Every block linearizes its content into a flat index space `0..<length`,
/// which the parent uses for exactly one thing: **ordering**. Who comes before
/// whom, what lies between two points, how to stitch two blocks' text together.
///
/// It deliberately does *not* use that space to decide **shape**. Hence
/// `rects(from:to:)` takes two endpoints rather than a `Range` — a `Range` has
/// already asserted that everything between its bounds is selected, which is
/// the linear assumption, and a table's selection is a rectangle. Handing over
/// the endpoints instead leaves the block that owns them free to decide what
/// lies between, and keeps the decoding of its own index space private.
///
/// ## Getting the four selection members for free
///
/// Two default paths cover every block in this package but one:
///
/// - **`TextBlock`** — "I am a stack of typeset lines." Declares a `TextRun`
///   and an origin; the four members come from the run.
/// - **`BlockStack`** — "I hold other blocks." Splits the endpoints across its
///   children and recurses.
///
/// `Table` is the exception, and writes its own — a rectangle over cells is not
/// derivable from a linear span. That it is the only exception is the design
/// working, not a gap in it.
protocol Block {

    /// The block's laid-out size, at the width it was built against.
    var size: CGSize { get }

    /// Draws into `ctx` with the block's top-left at `origin`, in the target
    /// view's (flipped, y-down) coordinates.
    ///
    /// `dirty` is in the same space, and is a permission to skip rather than a
    /// clip — the context is already clipped. A container uses it to avoid
    /// walking children that cannot be seen, which is what keeps a row holding
    /// a two-thousand-line code block affordable to scroll past.
    func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect)

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
    /// block-local coordinates.
    ///
    /// The endpoints arrive unordered — a drag runs in either direction.
    func rects(from: Int, to: Int) -> [CGRect]

    /// The plain text a selection between two indices copies as.
    func text(from: Int, to: Int) -> String
}

extension Block {

    /// The whole block selected.
    func fullRects() -> [CGRect] { rects(from: 0, to: length) }
}

/// A block with no selectable content — a thematic break, an image, a
/// decoration. Draws, indexes to nothing, copies as nothing.
///
/// Kept as a protocol rather than three lines repeated per type so that "this
/// one is not selectable" is a declaration at the conformance rather than
/// something a reader has to infer from four empty method bodies.
protocol OpaqueBlock: Block {}

extension OpaqueBlock {
    var length: Int { 0 }
    func index(at point: CGPoint) -> Int { 0 }
    func rects(from: Int, to: Int) -> [CGRect] { [] }
    func text(from: Int, to: Int) -> String { "" }
}

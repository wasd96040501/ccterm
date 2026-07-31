import AppKit

/// A vertical run of blocks — and itself a `Block`.
///
/// That last clause is the whole design. Because a stack is a block, a stack
/// can hold a stack, so a blockquote is a stack with a bar drawn beside it, a
/// list item is a stack with a marker drawn beside it, and a document is a
/// stack with nothing drawn beside it. None of them re-implements stacking, and
/// none of them writes a line of selection code.
///
/// The renderer this replaces had no such type: every composite carried its own
/// children in a bespoke enum and hand-rolled its own vertical arithmetic, which
/// is why a list item could hold only text or another list — a code block inside
/// one was not merely unstyled, it was unrepresentable.
///
/// ## What a stack does not do
///
/// It arranges; it does not **negotiate**. Children are measured independently,
/// so anything requiring agreement *between* siblings — a list's marker column
/// widening to fit `10.`, a table's columns sizing to their widest cell — needs
/// a thin block wrapping the stack to settle that first. Those two are the only
/// such cases in this package, and it is worth noticing that the table is
/// special in exactly the two ways anything can be: it negotiates, and its
/// selection is not linear.
struct BlockStack: Block {

    /// A child, its placement, and where its index space begins.
    struct Child {
        let block: Block

        /// Top-left in the stack's coordinates — already carrying the inset.
        let origin: CGPoint

        /// Index of the child's position 0 within the stack's flat space.
        let base: Int

        var frame: CGRect { CGRect(origin: origin, size: block.size) }
        var range: Range<Int> { base..<(base + block.length) }
    }

    let children: [Child]
    let size: CGSize
    let length: Int

    static let empty = BlockStack(children: [], size: .zero, length: 0)

    // MARK: - Build

    /// Stacks `blocks` top to bottom inside `width`, separated by `spacing` and
    /// indented by `inset`.
    ///
    /// The blocks must already have been built against the inner width
    /// (`width` minus the horizontal inset) — a block is a laid-out value, so
    /// the stack places what it is given rather than re-measuring it. Handing
    /// in children built at some other width is a caller error, and shows up as
    /// content that overflows its indent.
    static func make(
        _ blocks: [Block],
        width: CGFloat,
        spacing: CGFloat = 0,
        inset: NSEdgeInsets = NSEdgeInsets()
    ) -> BlockStack {
        make(
            blocks, width: width,
            gaps: Array(repeating: spacing, count: max(0, blocks.count - 1)),
            inset: inset)
    }

    /// The same, with the gap between each adjacent pair stated separately.
    ///
    /// A markdown document's vertical rhythm is not one number: the space a
    /// heading wants above it differs from the space it wants below, and a
    /// bordered block wants more than a paragraph. Rather than give every block
    /// its own padding — which would put half of each gap inside one block and
    /// half inside the next, and make the total invisible from either — the
    /// caller computes each pair's gap and hands over the list. The stack stays
    /// arithmetic either way.
    ///
    /// `gaps` shorter than `blocks.count - 1` leaves the remaining pairs flush;
    /// longer, the excess is ignored.
    static func make(
        _ blocks: [Block],
        width: CGFloat,
        gaps: [CGFloat],
        inset: NSEdgeInsets = NSEdgeInsets()
    ) -> BlockStack {
        guard !blocks.isEmpty else { return .empty }

        var children: [Child] = []
        children.reserveCapacity(blocks.count)

        var y = inset.top
        var base = 0

        for (index, block) in blocks.enumerated() {
            if index > 0, index - 1 < gaps.count { y += gaps[index - 1] }
            children.append(
                Child(block: block, origin: CGPoint(x: inset.left, y: y), base: base))
            y += block.size.height
            base += block.length
        }

        return BlockStack(
            children: children,
            size: CGSize(width: width, height: y + inset.bottom),
            length: base)
    }

    // MARK: - Draw

    func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
        for child in children {
            let top = origin.y + child.origin.y
            // Skipping, not clipping. A row holding a very long code block is
            // one tall cell whose `draw` is called with a viewport-sized dirty
            // rect; without this the cost of scrolling past it would be the
            // cost of drawing all of it, every frame.
            guard top < dirty.maxY, top + child.block.size.height > dirty.minY else { continue }
            child.block.draw(
                at: CGPoint(x: origin.x + child.origin.x, y: top), in: ctx, dirty: dirty)
        }
    }

    // MARK: - Selection

    func index(at point: CGPoint) -> Int {
        guard let index = childIndex(atY: point.y) else { return 0 }
        let child = children[index]
        let local = CGPoint(x: point.x - child.origin.x, y: point.y - child.origin.y)
        return child.base + child.block.index(at: local)
    }

    /// Splits the endpoints across children, and — this is the part that makes
    /// a table's rectangle possible — hands **both** endpoints to a single child
    /// whenever one child owns them, rather than deciding on its behalf what
    /// lies between.
    func rects(from: Int, to: Int) -> [CGRect] {
        let lo = min(from, to)
        let hi = max(from, to)
        guard hi > lo, let first = childIndex(containing: lo),
            let last = childIndex(containing: hi - 1)
        else { return [] }

        if first == last {
            let child = children[first]
            return child.block
                .rects(from: lo - child.base, to: hi - child.base)
                .map { $0.offsetBy(dx: child.origin.x, dy: child.origin.y) }
        }

        return (first...last).flatMap { index -> [CGRect] in
            let child = children[index]
            let start = max(lo, child.range.lowerBound) - child.base
            let end = min(hi, child.range.upperBound) - child.base
            guard end > start else { return [] }
            return child.block
                .rects(from: start, to: end)
                .map { $0.offsetBy(dx: child.origin.x, dy: child.origin.y) }
        }
    }

    func text(from: Int, to: Int) -> String {
        let lo = min(from, to)
        let hi = max(from, to)
        guard hi > lo, let first = childIndex(containing: lo),
            let last = childIndex(containing: hi - 1)
        else { return "" }

        let parts = (first...last).compactMap { index -> String? in
            let child = children[index]
            let start = max(lo, child.range.lowerBound) - child.base
            let end = min(hi, child.range.upperBound) - child.base
            guard end > start else { return nil }
            let text = child.block.text(from: start, to: end)
            return text.isEmpty ? nil : text
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Lookup

    /// Which child owns flat index `i`. Zero-length children — a rule, an image
    /// — occupy no index and are therefore never the answer.
    private func childIndex(containing i: Int) -> Int? {
        guard !children.isEmpty else { return nil }
        for (index, child) in children.enumerated() where child.range.contains(i) {
            return index
        }
        // Past the end: the last child that holds anything.
        return children.lastIndex { !$0.range.isEmpty }
    }

    /// Which child owns `y`, clamped to the first / last so that a click in the
    /// stack's own padding still resolves.
    private func childIndex(atY y: CGFloat) -> Int? {
        guard !children.isEmpty else { return nil }
        if y < children[0].origin.y { return 0 }
        for (index, child) in children.enumerated()
        where y < child.origin.y + child.block.size.height {
            return index
        }
        return children.count - 1
    }
}

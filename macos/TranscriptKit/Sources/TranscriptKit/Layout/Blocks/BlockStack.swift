import AppKit

/// A vertical run of blocks — and itself a `Block`.
///
/// That last clause is the whole design. Because a stack is a block, a stack
/// can hold a stack, so a blockquote is a stack with a bar beside it, a list item
/// is a stack behind a marker, and a document is a stack with nothing beside it.
/// None of them re-implements stacking, and none writes a line of selection code.
///
/// `spacing` is the stack's, one number, the way `NSStackView` has it. It is not
/// assembled from anything the children said: a child's own breathing room is
/// already inside the height it measured to, so the stack adds `spacing` and
/// nothing else. A document leaves it at zero and lets each block's own padding
/// set the rhythm, which is why the numbers are where they can be read next to
/// the thing they describe.
///
/// ## What a stack does not do
///
/// It arranges; it does not **negotiate**. Children are measured independently
/// against the same width, so anything needing agreement *between* siblings — a
/// list's marker column widening to fit `10.`, a table's columns sizing to their
/// widest cell — belongs to the type that wants it, which measures its parts and
/// settles the number before any stack sees it.
struct BlockStack: Block, @unchecked Sendable {

    let children: [Block]
    var spacing: CGFloat = 0

    init(_ children: [Block], spacing: CGFloat = 0) {
        self.children = children
        self.spacing = spacing
    }

    func measure(_ width: CGFloat) -> MeasuredBlock {
        Self.stack(children.map { $0.measure(width) }, spacing: spacing, width: width)
    }

    /// Packs children that have **already been measured**, at the width they were
    /// measured into.
    ///
    /// Split out of `measure` for one caller. A row whose document grew by a
    /// token re-measures only the blocks that actually changed and takes the rest
    /// back from `MarkdownMemo`, so it arrives here holding a mixture of fresh and
    /// reused children — and the packing arithmetic, the y cursor and the index
    /// bases, stays written once rather than a second time over there.
    ///
    /// It is also the reason reuse can ignore where a block sat before: every
    /// origin and every base is assigned in this loop, so a block that moved two
    /// positions down the document needs nothing done to it.
    static func stack(_ children: [MeasuredBlock], spacing: CGFloat, width: CGFloat) -> Measured {
        var placed: [Measured.Child] = []
        placed.reserveCapacity(children.count)

        var y: CGFloat = 0
        var base = 0

        for block in children {
            if !placed.isEmpty { y += spacing }
            placed.append(Measured.Child(block: block, origin: CGPoint(x: 0, y: y), base: base))
            y += block.size.height
            // Packed **contiguously** — no slot reserved for the newline
            // `text(from:to:)` puts between two children. `Table` reserves one and
            // says why; the difference is what the two are made of. An empty cell
            // is a place a reader means to select; a thematic break is not, and
            // giving it a position would let a drag stop *on* the rule and copy a
            // stray newline for it. The cost is that a zero-length child is
            // unreachable, which is exactly the intent.
            base += block.length
        }

        return Measured(children: placed, size: CGSize(width: width, height: y), length: base)
    }

    /// A measured stack: its children, where each sits, and where each one's
    /// index space begins.
    struct Measured: MeasuredBlock, @unchecked Sendable {

        struct Child {
            let block: MeasuredBlock

            /// Top-left in the stack's coordinates.
            let origin: CGPoint

            /// Index of this child's position 0 within the stack's flat space.
            let base: Int

            var frame: CGRect { CGRect(origin: origin, size: block.size) }
            var range: Range<Int> { base..<(base + block.length) }
        }

        let children: [Child]
        let size: CGSize
        let length: Int

        static let empty = Measured(children: [], size: .zero, length: 0)

        // MARK: - Paint

        /// Emits nothing of its own — a stack has no appearance. It walks, offsets,
        /// and lets each child say what it paints and how deep.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            for child in children {
                let top = origin.y + child.origin.y
                // Skipping, not clipping. A row holding a very long code block is
                // one tall cell painted with a viewport-sized dirty rect; without
                // this, scrolling past it would cost walking all of it, every frame.
                guard top < dirty.maxY, top + child.block.size.height > dirty.minY else {
                    continue
                }
                child.block.paint(
                    at: CGPoint(x: origin.x + child.origin.x, y: top), dirty: dirty, into: &list)
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
        /// a table's rectangle possible — hands **both** endpoints to a single
        /// child whenever one child owns them, rather than deciding on its behalf
        /// what lies between.
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

        /// Unlike `index(at:)`, this does **not** clamp to a child: a point in the
        /// gap between two blocks is on neither of them, and a character is a
        /// thing you are either pointing at or not.
        func characterIndex(at point: CGPoint) -> Int? {
            guard let index = childIndex(atY: point.y) else { return nil }
            let child = children[index]
            guard child.frame.contains(point) else { return nil }
            return
                child.block
                .characterIndex(
                    at: CGPoint(x: point.x - child.origin.x, y: point.y - child.origin.y)
                )
                .map { $0 + child.base }
        }

        /// The mirror of the above, and the same shape as `childRange(at:)`: find
        /// whose index it is, ask them in their own space, lift what comes back.
        func link(at index: Int) -> InlineLink? {
            guard let position = childIndex(containing: index) else { return nil }
            let child = children[position]
            return child.block.link(at: index - child.base).map { $0.lifted(by: child.base) }
        }

        func wordRange(at point: CGPoint) -> Range<Int> {
            childRange(at: point) { $0.wordRange(at: $1) }
        }

        func paragraphRange(at point: CGPoint) -> Range<Int> {
            childRange(at: point) { $0.paragraphRange(at: $1) }
        }

        /// Both granularities compose the same way: find whose point it is, ask
        /// them in their own space, shift what comes back. A word never spans two
        /// blocks, and neither does a paragraph — that is what being a separate
        /// block means.
        ///
        /// Decoded by point, and by the same clamping rule as `index(at:)` rather
        /// than the declining one `characterIndex(at:)` uses: a triple-click in
        /// the gap between two paragraphs has to take one of them.
        private func childRange(
            at point: CGPoint, _ ask: (MeasuredBlock, CGPoint) -> Range<Int>
        ) -> Range<Int> {
            guard let position = childIndex(atY: point.y) else { return 0..<0 }
            let child = children[position]
            let local = CGPoint(x: point.x - child.origin.x, y: point.y - child.origin.y)
            let range = ask(child.block, local)
            return (range.lowerBound + child.base)..<(range.upperBound + child.base)
        }

        // MARK: - Lookup

        /// Which child owns flat index `i`. Zero-length children — a rule, an
        /// image — occupy no index and are therefore never the answer.
        private func childIndex(containing i: Int) -> Int? {
            guard !children.isEmpty else { return nil }
            for (index, child) in children.enumerated() where child.range.contains(i) {
                return index
            }
            // Past the end: the last child that holds anything.
            return children.lastIndex { !$0.range.isEmpty }
        }

        /// Which child owns `y`, clamped to the first / last so a click in a gap
        /// still resolves.
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
}

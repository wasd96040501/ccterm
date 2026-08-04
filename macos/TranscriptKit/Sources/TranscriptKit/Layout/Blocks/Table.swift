import AppKit

/// A grid of cells on a bordered card: a tinted header band over zebra-striped
/// body rows.
///
/// **The block whose selection is a rectangle.** Every other block linearises
/// into a range, so "what lies between two points" is decided by the index space
/// itself. A table's is not: dragging from the second column down two rows takes
/// a *block* of cells, and the six cells the drag passed over on the way are not
/// part of it. That is the whole reason `MeasuredBlock.rects(from:to:)` takes two
/// endpoints instead of a `Range` — a range has already asserted the linear
/// answer, whereas endpoints leave the block that owns them free to decide. This
/// type is the one that decides differently.
///
/// Inside a cell, selection is per-character; the moment it crosses a cell
/// boundary it snaps to whole cells. Numbers and Excel behave the same way, and
/// for the same reason: leaving one cell is the user changing what they are
/// pointing at, from glyphs to structure.
///
/// **This is the one type besides `ListBuilder` that negotiates.** A stack measures its
/// children independently and so cannot size a column to the widest cell in it;
/// column widths are an agreement between siblings, settled here before anything
/// is laid out, and never visible outside this file.
struct Table: Block {

    /// A column's horizontal alignment. GFM's "unspecified" is not a case of its
    /// own — it lays out exactly as leading does, and a distinction that changes
    /// no geometry is one more thing to keep consistent for nothing.
    enum Alignment {
        case leading, center, trailing
    }

    /// The whole grid, header first, already squared off — source rows may be
    /// jagged, and short ones were padded with empty cells here so that nothing
    /// downstream has to ask whether a cell exists.
    private let grid: [[ShapedText]]

    private let columnCount: Int

    /// Per column, the widest `min-content` and `max-content` its cells reported,
    /// **without padding**. Both are properties of the text rather than of any
    /// width it might be placed in, so they are settled here rather than on the
    /// `measure` path — which is what takes column sizing from three typesetting
    /// passes per cell down to one. Padding and the floor are applied later,
    /// because those two are still `var`s a caller may change.
    private let intrinsics: [(min: CGFloat, max: CGFloat)]

    /// One entry per column, in column order. A missing entry is `.leading`.
    let alignments: [Alignment]

    // MARK: - Geometry

    var cellHorizontalPadding: CGFloat = 8
    var cellVerticalPadding: CGFloat = 10

    /// Floor on a column's minimum width. Without it, the min-content
    /// derivation collapses an empty or single-glyph column to a sliver.
    var minColumnWidth: CGFloat = 40

    /// The "structural" corner tier — data, code, grids — the same 6 the code
    /// card uses. A tight curve reads as engineering; the soft tier belongs to
    /// chat bubbles.
    var cornerRadius: CGFloat = 6

    /// Room outside the card, on top of the container's own spacing. A bordered
    /// edge crowds its neighbours more than a text edge does, so it buys back
    /// two points on each side — inside its own measured height, telling nobody.
    /// Identical in value and in reason to `CodeBlock.outerPadding`.
    var outerPadding: CGFloat = 2

    // MARK: - Colours

    var borderColor: NSColor = .separatorColor

    /// The body's row separators. Same weight as the border, a quieter colour,
    /// so the grid reads as one block rather than a lattice.
    var dividerColor: NSColor = dynamic(dark: 0.10, light: 0.06)

    /// Distinctly deeper than the zebra stripe, so the header reads as its own
    /// band rather than as one more body row.
    var headerBackgroundColor: NSColor = dynamic(dark: 0.14, light: 0.08)

    /// On odd body rows only. An eye-tracking aid across a wide row, meant to be
    /// near-invisible when you are not using it.
    var zebraBackgroundColor: NSColor = dynamic(dark: 0.04, light: 0.025)

    /// Header cells at the surrounding body size, one weight up. The caller
    /// supplies the face because the size belongs to the text around the table,
    /// not to the table.
    static func headerFont(_ body: NSFont) -> NSFont {
        .systemFont(ofSize: body.pointSize, weight: .semibold)
    }

    init(header: [ShapedText], rows: [[ShapedText]], alignments: [Alignment]) {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let grid = ([header] + rows).map { row in
            (0..<columnCount).map { $0 < row.count ? row[$0] : ShapedText.empty }
        }

        self.columnCount = columnCount
        self.grid = grid
        self.alignments = alignments
        self.intrinsics = (0..<columnCount).map { column in
            grid.reduce((min: CGFloat(0), max: CGFloat(0))) { widest, row in
                let cell = row[column].intrinsicWidths()
                let wide = ceil(cell.max)
                // An empty cell measures to nothing at both widths; clamping
                // keeps a column's min from exceeding its own max.
                let narrow = Swift.min(ceil(cell.min), wide)
                return (min: Swift.max(widest.min, narrow), max: Swift.max(widest.max, wide))
            }
        }
    }

    // MARK: - Measure

    func measure(_ width: CGFloat) -> MeasuredBlock {
        guard columnCount > 0, width > 0 else { return Measured.empty(width: width) }
        let columns = columnWidths(within: width)

        var cells: [[Measured.Cell]] = []
        cells.reserveCapacity(grid.count)
        var y = outerPadding
        var base = 0

        for row in grid {
            // Every cell in the row is typeset before any of them is placed: the
            // row's height is the tallest of them, and a cell cannot be given
            // its band until that is known.
            let texts = row.enumerated().map { column, cell in
                cell.typeset(width: max(1, columns[column] - cellHorizontalPadding * 2))
            }
            let height = (texts.map(\.size.height).max() ?? 0) + cellVerticalPadding * 2

            var laid: [Measured.Cell] = []
            laid.reserveCapacity(texts.count)
            var x: CGFloat = 0
            for (column, text) in texts.enumerated() {
                let frame = CGRect(x: x, y: y, width: columns[column], height: height)
                laid.append(
                    Measured.Cell(
                        text: text,
                        textOrigin: CGPoint(
                            x: textX(in: frame, textWidth: text.size.width, column: column),
                            y: y + cellVerticalPadding),
                        frame: frame,
                        base: base))
                // One more than the cell holds — see `Cell.lastIndex`. `BlockStack`
                // packs its children with no such slot, and says why there; a grid
                // is the case where the empty thing is still a place.
                base += text.length + 1
                x += columns[column]
            }
            cells.append(laid)
            y += height
        }

        return Measured(
            cells: cells,
            body: CGRect(
                x: 0, y: outerPadding,
                width: columns.reduce(0, +), height: y - outerPadding),
            size: CGSize(width: width, height: y + outerPadding),
            length: base,
            cornerRadius: cornerRadius,
            borderColor: borderColor,
            dividerColor: dividerColor,
            headerBackgroundColor: headerBackgroundColor,
            zebraBackgroundColor: zebraBackgroundColor)
    }

    /// Column widths, under the CSS min/max model.
    ///
    /// A cell offers two numbers: its **min** — what the text settles at when
    /// typeset into a width of one point, which is CSS `min-content`, the natural
    /// break (Latin per word, CJK per glyph) — and its **max**, the width it
    /// wants with no wrapping at all. Both were settled in `init`; what is left
    /// here is padding, the floor, and the three branches those two sums can fall
    /// into against the space available.
    private func columnWidths(within width: CGFloat) -> [CGFloat] {
        var mins = intrinsics.map { $0.min + cellHorizontalPadding * 2 }
        var maxes = intrinsics.map { $0.max + cellHorizontalPadding * 2 }

        for column in 0..<columnCount {
            mins[column] = max(mins[column], minColumnWidth)
            maxes[column] = max(maxes[column], mins[column])
        }

        let minSum = mins.reduce(0, +)
        let maxSum = maxes.reduce(0, +)

        // Everything fits unwrapped. The slack goes on the last column rather
        // than being shared out, so the table fills the row with its content
        // left-anchored — sharing it makes narrow columns mid-table look padded
        // for no reason.
        if maxSum <= width {
            var widths = maxes
            widths[widths.count - 1] += width - maxSum
            return widths
        }

        // Something has to wrap. Start every column at its min and hand out the
        // remainder in proportion to what each column *wanted*, so a column of
        // prose absorbs the slack and a column of single words barely moves.
        if minSum < width {
            let slack = width - minSum
            return zip(mins, maxes).map { $0 + slack * ($1 / max(maxSum, 1)) }
        }

        // Narrower than the mins themselves. Scale them down together: some text
        // will break badly, which is a better failure than a table hanging over
        // the edge of the row.
        return mins.map { max(1, floor($0 * (width / max(minSum, 1)))) }
    }

    /// Where a cell's text starts, given its band and how wide the text came out.
    /// Trailing text falls back to the leading pad rather than tucking underneath
    /// it, for the column too narrow to hold its own content.
    private func textX(in frame: CGRect, textWidth: CGFloat, column: Int) -> CGFloat {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading:
            return frame.minX + cellHorizontalPadding
        case .center:
            return frame.minX + max(0, (frame.width - textWidth) / 2)
        case .trailing:
            return frame.minX + max(cellHorizontalPadding, frame.width - cellHorizontalPadding - textWidth)
        }
    }

    /// A translucent white / black overlay, resolved against whatever appearance
    /// is current when it is drawn. Tints rather than fixed colours so the card
    /// keeps its relationship to whatever it is sitting on.
    private static func dynamic(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark)
                : NSColor(white: 0, alpha: light)
        }
    }

    // MARK: - Measured

    /// A measured table: its cells with their bands, and the card they sit on.
    struct Measured: MeasuredBlock, @unchecked Sendable {

        struct Cell {
            let text: TypesetText

            /// Top-left of the text in block-local coordinates — the cell's
            /// padding and its column's alignment, already applied.
            let textOrigin: CGPoint

            /// The whole cell band: column width by row height, padding
            /// included. What a rectangular selection fills, and what
            /// hit-testing partitions the table by.
            let frame: CGRect

            /// This cell's position 0 in the table's flat index space.
            let base: Int

            /// A cell owns **one more position than it has characters**, so that
            /// an empty cell is still somewhere a selection can start and two
            /// adjacent empty cells never decode to the same place. `length` is a
            /// count of positions, not of characters, which is what leaves room
            /// for this.
            var lastIndex: Int { base + text.length }
        }

        /// Row 0 is the header. Rectangular: every row holds the same count.
        let cells: [[Cell]]

        /// The card, in block-local coordinates — the grid without the outer
        /// padding, and narrower than the block when the columns did not use the
        /// whole width.
        let body: CGRect

        let size: CGSize
        let length: Int

        let cornerRadius: CGFloat
        let borderColor: NSColor
        let dividerColor: NSColor
        let headerBackgroundColor: NSColor
        let zebraBackgroundColor: NSColor

        static func empty(width: CGFloat) -> Measured {
            Measured(
                cells: [], body: .zero, size: CGSize(width: width, height: 0), length: 0,
                cornerRadius: 0, borderColor: .clear, dividerColor: .clear,
                headerBackgroundColor: .clear, zebraBackgroundColor: .clear)
        }

        // MARK: - Paint

        /// Row tints and seams are `.background`, glyphs `.content`, the border
        /// `.overlay`. Within `.background` the seams are emitted after the tints
        /// and so land on them — the one place this type leans on order inside a
        /// phase.
        ///
        /// **No clip.** The rounded corners used to come from clipping every fill
        /// to the card, which is scoped state and has nowhere to live in a flat
        /// list. It was never doing more than four corners' worth of work: seams
        /// sit at interior row boundaries, where the card's edges are straight,
        /// and only the first and last rows' tints reach a corner at all. Those
        /// two are emitted as paths rounded on the side that touches one.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            guard !cells.isEmpty else { return }
            let card = body.offsetBy(dx: origin.x, dy: origin.y)
            let last = cells.count - 1

            for index in cells.indices {
                let band = rowRect(index).offsetBy(dx: origin.x, dy: origin.y)
                guard visible(band, in: dirty), let fill = rowFill(index) else { continue }
                list.append(
                    .fill(
                        Self.path(
                            band, radius: cornerRadius,
                            roundingTop: index == 0, roundingBottom: index == last),
                        fill))
            }

            // The header / body seam is the border colour so the header reads as
            // a sealed band; body seams stay muted.
            for index in cells.indices.dropLast() {
                let band = rowRect(index).offsetBy(dx: origin.x, dy: origin.y)
                guard visible(band, in: dirty) else { continue }
                list.append(
                    .fill(
                        CGRect(x: card.minX, y: band.maxY - 0.5, width: card.width, height: 1),
                        index == 0 ? borderColor : dividerColor))
            }

            for row in cells {
                guard let first = row.first,
                    visible(first.frame.offsetBy(dx: origin.x, dy: origin.y), in: dirty)
                else { continue }
                for cell in row {
                    list.append(
                        .text(
                            cell.text,
                            at: CGPoint(
                                x: origin.x + cell.textOrigin.x, y: origin.y + cell.textOrigin.y)))
                }
            }

            // Inset by half the stroke so the 1pt border lands on the pixel grid
            // rather than straddling it — sharp at 1× and 2× alike.
            list.append(
                .stroke(
                    roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                    radius: cornerRadius, width: 1, borderColor))
        }

        /// A rectangle rounded on the top, the bottom, both, or neither — a row
        /// band shaped to whichever end of the card it sits at.
        private static func path(
            _ rect: CGRect, radius: CGFloat, roundingTop: Bool, roundingBottom: Bool
        ) -> CGPath {
            let top = roundingTop ? radius : 0
            let bottom = roundingBottom ? radius : 0
            guard top > 0 || bottom > 0 else { return CGPath(rect: rect, transform: nil) }

            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: top)
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: top)
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: bottom)
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: bottom)
            path.closeSubpath()
            return path
        }

        /// `nil` for an unstriped row. Body row 0 stays clear so the stripe reads
        /// as alternating from the first row down rather than starting doubled
        /// under the header.
        private func rowFill(_ index: Int) -> NSColor? {
            if index == 0 { return headerBackgroundColor }
            return (index - 1).isMultiple(of: 2) ? nil : zebraBackgroundColor
        }

        /// A row's full-width band. Every cell in a row shares its vertical
        /// extent, so the first one answers for all of them.
        private func rowRect(_ index: Int) -> CGRect {
            guard let first = cells[index].first else { return .zero }
            return CGRect(
                x: body.minX, y: first.frame.minY, width: body.width, height: first.frame.height)
        }

        private func visible(_ rect: CGRect, in dirty: CGRect) -> Bool {
            rect.minY < dirty.maxY && rect.maxY > dirty.minY
        }

        // MARK: - Selection

        func index(at point: CGPoint) -> Int {
            guard let cell = cell(at: point) else { return 0 }
            return cell.base
                + cell.text.index(
                    at: CGPoint(x: point.x - cell.textOrigin.x, y: point.y - cell.textOrigin.y))
        }

        /// Both endpoints decode back to a cell, and the pair of cells names a
        /// rectangle. One cell means the drag never left it, and the selection is
        /// the text's own — character-precise. Anything wider is whole cells.
        func rects(from: Int, to: Int) -> [CGRect] {
            guard let (a, b) = corners(from, to) else { return [] }

            if a.row == b.row, a.column == b.column {
                let cell = cells[a.row][a.column]
                guard b.character > a.character else { return [] }
                return cell.text.rects(from: a.character, to: b.character)
                    .map { $0.offsetBy(dx: cell.textOrigin.x, dy: cell.textOrigin.y) }
            }

            return rectangle(a, b).flatMap { row in
                row.map(\.frame)
            }
        }

        /// Tab between cells, newline between rows — what a spreadsheet expects
        /// on paste, and what TextEdit produces going the other way.
        func text(from: Int, to: Int) -> String {
            guard let (a, b) = corners(from, to) else { return "" }

            if a.row == b.row, a.column == b.column {
                guard b.character > a.character else { return "" }
                return cells[a.row][a.column].text.text(from: a.character, to: b.character)
            }

            return rectangle(a, b)
                .map { row in row.map(\.text.attributed.string).joined(separator: "\t") }
                .joined(separator: "\n")
        }

        /// Whichever cell the point is in answers in its own space. `cell(at:)`
        /// clamps to the nearest edge cell, so the containment check is what keeps
        /// a point outside the card from picking up its last cell's glyphs.
        func characterIndex(at point: CGPoint) -> Int? {
            guard let cell = cell(at: point), cell.frame.contains(point) else { return nil }
            return
                cell.text
                .characterIndex(
                    at: CGPoint(x: point.x - cell.textOrigin.x, y: point.y - cell.textOrigin.y)
                )
                .map { $0 + cell.base }
        }

        /// The same shape as `wordRange(at:)`: decode to a cell, ask it in its own
        /// space, lift what comes back. A separator position decodes to a cell at
        /// `character == text.length`, which the text declines — so the slots
        /// between cells hold no link, which is what they are for.
        func link(at index: Int) -> InlineLink? {
            guard length > 0 else { return nil }
            let at = position(of: index)
            let cell = cells[at.row][at.column]
            return cell.text.link(at: at.character).map { $0.lifted(by: cell.base) }
        }

        /// Decoded by point like the two above, and the cell answers in its own
        /// space. `cell(at:)` clamps, which is what a click in the padding around
        /// a cell's glyphs needs — unlike `characterIndex(at:)`, this one has to
        /// resolve.
        func wordRange(at point: CGPoint) -> Range<Int> {
            guard let cell = cell(at: point), cell.text.length > 0 else { return 0..<0 }
            let word = cell.text.wordRange(
                at: CGPoint(x: point.x - cell.textOrigin.x, y: point.y - cell.textOrigin.y))
            return (cell.base + word.lowerBound)..<(cell.base + word.upperBound)
        }

        /// A triple-click takes the whole cell rather than a paragraph inside it —
        /// what a browser does with a `<td>`, and what Numbers and Excel do. The
        /// grid is the structure a reader is pointing at once they have stopped
        /// pointing at glyphs.
        ///
        /// Which also makes this the one member of the family with no line-end
        /// ambiguity to settle: the answer is the cell, and a point resolves to a
        /// cell whether or not it landed on a glyph.
        func paragraphRange(at point: CGPoint) -> Range<Int> {
            guard let cell = cell(at: point) else { return 0..<0 }
            return cell.base..<cell.lastIndex
        }

        // MARK: - Lookup

        /// The two endpoints as grid positions, ordered. `nil` when the selection
        /// is empty or the table holds nothing.
        private func corners(_ from: Int, _ to: Int) -> (a: Position, b: Position)? {
            let lo = min(from, to)
            let hi = max(from, to)
            guard hi > lo, length > 0 else { return nil }
            // `hi` is exclusive, and one past the last position is not a place —
            // clamp it back onto the grid before decoding.
            let a = position(of: lo)
            let b = position(of: min(hi, length - 1))
            return (a, b)
        }

        private struct Position {
            let row: Int
            let column: Int
            let character: Int
        }

        /// Which cell owns a flat index, and where inside it.
        ///
        /// Linear, like `TypesetText`'s line lookup and for the same reason: a
        /// table that is large enough for the walk to matter is large enough that
        /// its typesetting dominates by orders of magnitude.
        private func position(of index: Int) -> Position {
            let clamped = max(0, min(index, length - 1))
            for (row, cells) in cells.enumerated() {
                for (column, cell) in cells.enumerated() where clamped <= cell.lastIndex {
                    return Position(row: row, column: column, character: clamped - cell.base)
                }
            }
            let row = cells.count - 1
            let column = cells[row].count - 1
            return Position(
                row: row, column: column, character: cells[row][column].text.length)
        }

        /// Every cell inside the block the two corners span.
        private func rectangle(_ a: Position, _ b: Position) -> [[Cell]] {
            (min(a.row, b.row)...max(a.row, b.row)).map { row in
                (min(a.column, b.column)...max(a.column, b.column)).map { cells[row][$0] }
            }
        }

        /// Which cell a point lands in, clamped to the nearest edge cell. Cells
        /// tile the card with no gaps, so every interior point is in exactly one.
        private func cell(at point: CGPoint) -> Cell? {
            guard !cells.isEmpty, !cells[0].isEmpty else { return nil }
            let row = cells.firstIndex { $0[0].frame.maxY > point.y } ?? cells.count - 1
            let column = cells[row].firstIndex { $0.frame.maxX > point.x } ?? cells[row].count - 1
            return cells[row][column]
        }
    }
}

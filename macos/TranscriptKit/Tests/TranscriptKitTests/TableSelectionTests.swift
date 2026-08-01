import AppKit
import XCTest

@testable import TranscriptKit

/// The one block whose selection is not a range.
///
/// Everything else in the suite can assume that selecting from A to B takes
/// everything between them; a table is the counter-example the two-endpoint
/// signature on `MarkdownBlock.rects(from:to:)` exists for. So these tests are
/// mostly about what a selection *excludes* — the cells a drag passed over on
/// its way from one corner to the other, which are not part of the answer.
///
/// No window, no mount: a measured block is a value and answers the same on or
/// off screen.
final class TableSelectionTests: XCTestCase {

    // MARK: - Fixtures

    private func cell(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    /// A 3×3 grid whose every cell names its own position, so a selection that
    /// picked up the wrong one says which.
    private func grid() -> Table {
        Table(
            header: ["h0", "h1", "h2"].map(cell),
            rows: [
                ["a0", "a1", "a2"].map(cell),
                ["b0", "b1", "b2"].map(cell),
            ],
            alignments: [.leading, .center, .trailing])
    }

    /// Every cell's band, row-major — a whole-table selection is a rectangle over
    /// all of them, so this is also the assertion that the full range works.
    private func bands(_ block: MarkdownBlock, count: Int) throws -> [CGRect] {
        let rects = block.fullRects()
        // Throws rather than only failing: every test here indexes into what
        // comes back, so a wrong count has to stop the test instead of letting
        // it run on into a crash that says nothing.
        XCTAssertEqual(rects.count, count)
        return try XCTUnwrap(rects.count == count ? rects : nil)
    }

    private func middle(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - Measure

    func testTableReportsTheWidthItWasMeasuredInto() {
        XCTAssertEqual(grid().measure(400).size.width, 400)
    }

    /// The negotiation a stack cannot do: a column is as wide as its widest cell
    /// needs, not its share of the row.
    func testColumnsSizeToTheirContentRatherThanSplittingEvenly() throws {
        let table = Table(
            header: ["a very long header indeed", "n"].map(cell),
            rows: [["x", "y"].map(cell)],
            alignments: [])
        let cells = try bands(table.measure(400), count: 4)

        XCTAssertGreaterThan(cells[0].width, cells[1].width)
        // Cells tile the card edge to edge — no gap for a point to fall into.
        XCTAssertEqual(cells[0].maxX, cells[1].minX, accuracy: 0.5)
    }

    /// Source rows are allowed to be short. The grid that comes out is not.
    func testJaggedRowsAreSquaredOff() throws {
        let table = Table(
            header: ["h0", "h1", "h2"].map(cell),
            rows: [["a0"].map(cell)],
            alignments: [])
        _ = try bands(table.measure(400), count: 6)
    }

    // MARK: - Inside one cell

    /// A drag that never leaves a cell selects glyphs, not the cell.
    func testSelectionInsideOneCellIsCharacterPrecise() throws {
        let table = Table(
            header: ["head"].map(cell), rows: [["alpha"].map(cell)], alignments: [])
        let block = table.measure(400)
        let cells = try bands(block, count: 2)

        // The left edge of a cell resolves to its first position, which is where
        // that cell's index space starts.
        let base = block.index(at: CGPoint(x: cells[1].minX, y: cells[1].midY))

        XCTAssertEqual(block.text(from: base + 1, to: base + 4), "lph")
        let rects = block.rects(from: base + 1, to: base + 4)
        XCTAssertEqual(rects.count, 1)
        XCTAssertLessThan(try XCTUnwrap(rects.first).width, cells[1].width)
    }

    // MARK: - Across cells

    /// The load-bearing case. Dragging down one column takes that column — the
    /// six cells to either side lie between the endpoints in the flat index
    /// space, and are not selected.
    func testSelectionAcrossCellsTakesARectangleNotEverythingBetween() throws {
        let block = grid().measure(400)
        let cells = try bands(block, count: 9)

        let from = block.index(at: middle(of: cells[1]))  // header, middle column
        let to = block.index(at: middle(of: cells[7]))  // last row, middle column

        XCTAssertEqual(block.rects(from: from, to: to).count, 3)
        XCTAssertEqual(block.text(from: from, to: to), "h1\na1\nb1")
    }

    /// A rectangle two cells wide copies as a row of tab-separated cells, which
    /// is what a spreadsheet expects on paste.
    func testRectangleCopiesAsTabsWithinRowsAndNewlinesBetween() throws {
        let block = grid().measure(400)
        let cells = try bands(block, count: 9)

        let from = block.index(at: middle(of: cells[0]))
        let to = block.index(at: middle(of: cells[4]))
        XCTAssertEqual(block.text(from: from, to: to), "h0\th1\na0\ta1")
    }

    /// Endpoints arrive in either order — a drag runs both ways.
    func testEndpointsAreOrderIndependent() throws {
        let block = grid().measure(400)
        let cells = try bands(block, count: 9)

        let a = block.index(at: middle(of: cells[0]))
        let b = block.index(at: middle(of: cells[4]))
        XCTAssertEqual(block.text(from: b, to: a), block.text(from: a, to: b))
    }

    // MARK: - Cells with nothing in them

    /// An empty cell holds no characters but is still a place: it can be clicked
    /// into, and it is not the same place as its neighbour. That is what the
    /// extra position per cell buys — with one position per *character*, two
    /// adjacent empty cells would decode to the same index and a selection could
    /// not tell them apart.
    func testAnEmptyCellIsStillItsOwnPlace() throws {
        let table = Table(
            header: ["h0", "h1"].map(cell),
            rows: [["", ""].map(cell)],
            alignments: [])
        let block = table.measure(400)
        let cells = try bands(block, count: 4)

        let left = block.index(at: middle(of: cells[2]))
        let right = block.index(at: middle(of: cells[3]))
        XCTAssertNotEqual(left, right)

        // And a selection spanning both is a two-cell rectangle, not nothing.
        XCTAssertEqual(block.rects(from: left, to: right).count, 2)
    }

    // MARK: - Hit-testing

    /// Every point resolves, including the ones outside the table — the caller
    /// knows less about where the content is than the block does.
    func testHitTestClampsToTheNearestCell() {
        let block = grid().measure(400)

        XCTAssertEqual(block.index(at: CGPoint(x: -500, y: -500)), 0)
        XCTAssertEqual(block.index(at: CGPoint(x: 10_000, y: 10_000)), block.length - 1)
    }

    // MARK: - As a child

    /// Inside a stack the table is just another child: its indices shift by the
    /// stack's base, its rectangles by its origin, and the rectangle stays a
    /// rectangle.
    func testATableInsideAStackKeepsItsRectangle() throws {
        let paragraph = Paragraph(cell("intro"))
        let stack = BlockStack([paragraph, grid()], spacing: 12).measure(400)

        let offset = paragraph.measure(400).size.height + 12
        let inTable = CGPoint(x: 10, y: offset + 10)
        let start = stack.index(at: inTable)

        XCTAssertGreaterThanOrEqual(start, "intro".utf16.count)
        XCTAssertTrue(stack.text(from: 0, to: stack.length).hasPrefix("intro\n"))
        XCTAssertEqual(try XCTUnwrap(stack.rects(from: 0, to: 5).first).minY, 0, accuracy: 0.5)
    }
}

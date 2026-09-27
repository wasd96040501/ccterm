import XCTest

@testable import TranscriptKit

/// The arithmetic half of a selection across rows — which part of each row it
/// covers, and how its ends are renumbered through a mutation — which needs no
/// window. `SelectionTests` is the other half, mounted.
final class TextSelectionTests: XCTestCase {

    private let a = TranscriptRow.ID(UUID())
    private let b = TranscriptRow.ID(UUID())

    /// From row 2 at index 5 to row 4 at index 3, dragged in the given direction.
    private func selection(downwards: Bool = true) -> TextSelection {
        var selection = TextSelection(row: 2, id: a, range: 5..<5)
        selection.focus = .init(row: 4, id: b, index: 3)
        if !downwards { swap(&selection.anchor, &selection.focus) }
        return selection
    }

    // MARK: - What each row covers

    func testTheFirstRowIsCoveredFromTheStartToItsEnd() {
        XCTAssertEqual(selection().range(inRow: 2, length: 20), 5..<20)
    }

    func testARowBetweenTheEndsIsCoveredWhole() {
        XCTAssertEqual(selection().range(inRow: 3, length: 12), 0..<12)
    }

    func testTheLastRowIsCoveredFromItsStartToTheEnd() {
        XCTAssertEqual(selection().range(inRow: 4, length: 20), 0..<3)
    }

    func testRowsOutsideAreNotCovered() {
        XCTAssertNil(selection().range(inRow: 1, length: 20))
        XCTAssertNil(selection().range(inRow: 5, length: 20))
    }

    /// The direction of the drag changes nothing about what is covered.
    func testAnUpwardDragCoversTheSameRows() {
        let down = selection(downwards: true)
        let up = selection(downwards: false)
        for row in 1...5 {
            XCTAssertEqual(up.range(inRow: row, length: 20), down.range(inRow: row, length: 20))
        }
    }

    /// An end left past a row that has since got shorter covers what is there.
    func testAnEndPastTheRowsLengthIsClamped() {
        XCTAssertEqual(selection().range(inRow: 4, length: 2), 0..<2)
        XCTAssertNil(selection().range(inRow: 2, length: 4))
    }

    func testACaretCoversNothing() {
        let caret = TextSelection(row: 2, id: a, range: 5..<5)
        XCTAssertTrue(caret.isEmpty)
        XCTAssertNil(caret.range(inRow: 2, length: 20))
    }

    func testContainmentIsInReadingOrderAcrossRows() {
        let selection = selection(downwards: false)
        XCTAssertFalse(selection.contains(row: 2, index: 4))
        XCTAssertTrue(selection.contains(row: 2, index: 5))
        XCTAssertTrue(selection.contains(row: 3, index: 999))
        XCTAssertTrue(selection.contains(row: 4, index: 2))
        XCTAssertFalse(selection.contains(row: 4, index: 3))
    }

    // MARK: - Through a mutation

    /// Inserting at an end's row puts the new row above it, so it moves — the
    /// same running total as `ScrollAnchor`, counted against each end on its own.
    ///
    /// Positions are post-insertion: rows land at 0 and 3, so the old row 2 is
    /// pushed to 3 by the first and then sits *at* the second, which pushes it to
    /// 4; the old row 4 ends at 6, and 9 is below it.
    func testInsertingRenumbersEachEndByTheRowsAboveIt() {
        let shifted = selection().shifted(byRowsInserted: IndexSet([0, 3, 9]))
        XCTAssertEqual(shifted.anchor.row, 4)
        XCTAssertEqual(shifted.focus.row, 6)
        XCTAssertEqual(shifted.anchor.index, 5)
        XCTAssertEqual(shifted.focus.index, 3)
    }

    func testRelocatingFindsBothEndsByIdentity() {
        let relocated = selection().relocated(to: [a: 7, b: 1])
        XCTAssertEqual(relocated?.anchor.row, 7)
        XCTAssertEqual(relocated?.focus.row, 1)
    }

    func testRelocatingWithoutAnEndsRowDropsTheSelection() {
        XCTAssertNil(selection().relocated(to: [a: 7]))
    }
}

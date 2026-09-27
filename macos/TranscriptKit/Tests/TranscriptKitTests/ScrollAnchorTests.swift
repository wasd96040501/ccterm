import XCTest

@testable import TranscriptKit

/// Renumbering an anchor through an insertion or a removal — the arithmetic half
/// of scroll anchoring, which needs no window.
///
/// `@testable` rather than a public accessor: the type is an implementation
/// detail, and the alternative to reaching it directly is inferring the
/// arithmetic from a scroll offset three layers away, where a wrong answer and a
/// wrong clamp look the same.
final class ScrollAnchorTests: XCTestCase {

    // MARK: - Insertion

    func testInsertingAboveTheAnchorPushesItDown() {
        let anchor = ScrollAnchor.row(5, offsetFromTop: 12)
        XCTAssertEqual(
            anchor.shifted(byRowsInserted: IndexSet(0..<3)), .row(8, offsetFromTop: 12))
    }

    /// Inserting *at* the anchor's index puts a new row above it, so it moves.
    func testInsertingAtTheAnchorPushesItDown() {
        let anchor = ScrollAnchor.row(5, offsetFromTop: 0)
        XCTAssertEqual(
            anchor.shifted(byRowsInserted: IndexSet(integer: 5)), .row(6, offsetFromTop: 0))
    }

    func testInsertingBelowTheAnchorLeavesItAlone() {
        let anchor = ScrollAnchor.row(5, offsetFromTop: 3)
        XCTAssertEqual(
            anchor.shifted(byRowsInserted: IndexSet(integer: 6)), .row(5, offsetFromTop: 3))
    }

    /// Only the indexes that land above the anchor count, and they count against
    /// its moving position — inserting at 0 and at 8 shifts a row-5 anchor by one,
    /// not two.
    func testInsertingOnBothSidesCountsOnlyTheOnesAbove() {
        let anchor = ScrollAnchor.row(5, offsetFromTop: 0)
        XCTAssertEqual(
            anchor.shifted(byRowsInserted: IndexSet([0, 8])), .row(6, offsetFromTop: 0))
    }

    // MARK: - Removal

    func testRemovingAboveTheAnchorPullsItUp() {
        let anchor = ScrollAnchor.row(10, offsetFromTop: 7)
        XCTAssertEqual(
            anchor.shifted(byRowsRemoved: IndexSet(2..<5)), .row(7, offsetFromTop: 7))
    }

    func testRemovingBelowTheAnchorLeavesItAlone() {
        let anchor = ScrollAnchor.row(10, offsetFromTop: 7)
        XCTAssertEqual(
            anchor.shifted(byRowsRemoved: IndexSet(11..<20)), .row(10, offsetFromTop: 7))
    }

    /// The anchor row itself is gone, so the next survivor takes its place at the
    /// top of the viewport — and the offset into a row that no longer exists goes
    /// with it.
    func testRemovingTheAnchorRowFallsToTheNextSurvivor() {
        let anchor = ScrollAnchor.row(10, offsetFromTop: 7)
        XCTAssertEqual(
            anchor.shifted(byRowsRemoved: IndexSet(integer: 10)), .row(10, offsetFromTop: 0))
    }

    /// A run swallowing the anchor: old row 13 survives and lands at 10, since
    /// three rows before it went too.
    func testRemovingARunAroundTheAnchorLandsOnTheFirstRowAfterIt() {
        let anchor = ScrollAnchor.row(11, offsetFromTop: 7)
        XCTAssertEqual(
            anchor.shifted(byRowsRemoved: IndexSet(10..<13)), .row(10, offsetFromTop: 0))
    }

    /// Removing through the end leaves no survivor, and the index runs past the
    /// last row on purpose — `TranscriptView` clamps it against the row count it
    /// has and this arithmetic never needs one.
    func testRemovingThroughTheEndLeavesTheIndexPastTheLastRow() {
        let anchor = ScrollAnchor.row(11, offsetFromTop: 7)
        XCTAssertEqual(anchor.shifted(byRowsRemoved: IndexSet(10..<14)), .row(10, offsetFromTop: 0))
    }

    // MARK: - Tail

    func testTailSurvivesEveryShift() {
        XCTAssertEqual(ScrollAnchor.tail.shifted(byRowsInserted: IndexSet(0..<9)), .tail)
        XCTAssertEqual(ScrollAnchor.tail.shifted(byRowsRemoved: IndexSet(0..<9)), .tail)
    }
}

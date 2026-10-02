import XCTest

@testable import ccterm

/// What a live page's next rows ask of the transcript: appends, a growing
/// last row, rows that go, rows that change place.
final class PageRowChangesTests: XCTestCase {

    private func row(_ id: String, _ text: String = "") -> PageRow {
        PageRow(id: PageRow.ID(entry: id, part: .main), kind: .markdown(text))
    }

    private func rows(_ ids: String...) -> [PageRow] {
        ids.map { row($0) }
    }

    /// Applies `changes` the way a batch does — removals, inserts, reloads in
    /// call order — to the ids of `old`, taking inserted and reloaded rows
    /// from `new`; the result must be `new`.
    private func applied(_ changes: PageRow.Changes, to old: [PageRow], toward new: [PageRow]) -> [PageRow] {
        var result = old
        for index in changes.removed.reversed() { result.remove(at: index) }
        for index in changes.inserted { result.insert(new[index], at: index) }
        for index in changes.reloaded { result[index] = new[index] }
        return result
    }

    private func assertTurns(
        _ old: [PageRow], into new: [PageRow], file: StaticString = #filePath, line: UInt = #line
    )
        -> PageRow.Changes
    {
        let changes = PageRow.changes(from: old, to: new)
        XCTAssertEqual(applied(changes, to: old, toward: new), new, file: file, line: line)
        return changes
    }

    func testEqualListsChangeNothing() {
        XCTAssertTrue(PageRow.changes(from: rows("a", "b"), to: rows("a", "b")).isEmpty)
        XCTAssertTrue(PageRow.changes(from: [], to: []).isEmpty)
    }

    func testAppendedRowsAreInsertedAtTheEnd() {
        let changes = assertTurns(rows("a"), into: rows("a", "b", "c"))
        XCTAssertEqual(changes, PageRow.Changes(inserted: IndexSet(1...2)))
    }

    func testAGrowingLastRowIsReloadedInTheNewNumbering() {
        let old = [row("a"), row("b", "he")]
        let new = [row("a"), row("b", "hello"), row("c")]
        let changes = assertTurns(old, into: new)
        XCTAssertEqual(changes, PageRow.Changes(inserted: IndexSet(integer: 2), reloaded: IndexSet(integer: 1)))
    }

    /// A reload is named by where the row is once the removals and inserts
    /// before it have landed — not where it was.
    func testAReloadFollowsTheRowsRemovedAndInsertedAbove() {
        let old = [row("x"), row("a"), row("b", "1")]
        let new = [row("n1"), row("n2"), row("a"), row("b", "2")]
        let changes = assertTurns(old, into: new)
        XCTAssertEqual(changes.removed, IndexSet(integer: 0))
        XCTAssertEqual(changes.inserted, IndexSet(0...1))
        XCTAssertEqual(changes.reloaded, IndexSet(integer: 3))
    }

    func testRowsThatGoAreRemovedByTheirOldIndexes() {
        let changes = assertTurns(rows("a", "b", "c", "d"), into: rows("b", "d"))
        XCTAssertEqual(changes, PageRow.Changes(removed: IndexSet([0, 2])))
    }

    func testARowThatChangesKindIsReloaded() {
        let id = PageRow.ID(entry: "a", part: .main)
        let old = [PageRow(id: id, kind: .markdown("x"))]
        let new = [PageRow(id: id, kind: .interruption)]
        XCTAssertEqual(PageRow.changes(from: old, to: new).reloaded, IndexSet(integer: 0))
    }

    func testRowsThatSwapPlacesAreRemovedAndInsertedAgain() {
        let changes = assertTurns(rows("a", "b", "c"), into: rows("c", "a", "b"))
        XCTAssertTrue(changes.reloaded.isEmpty)
        XCTAssertEqual(changes.removed.count, 1)
        XCTAssertEqual(changes.inserted.count, 1)
    }

    func testAnyTwoListsTurnIntoEachOther() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let old = (0..<12).filter { _ in Bool.random(using: &generator) }.shuffled(using: &generator)
            let new = (0..<12).filter { _ in Bool.random(using: &generator) }.shuffled(using: &generator)
            let oldRows = old.map { row("\($0)", "old") }
            let newRows = new.map { row("\($0)", Bool.random(using: &generator) ? "old" : "new") }
            _ = assertTurns(oldRows, into: newRows)
        }
    }
}

import ExactListTestSupport
import XCTest

@testable import ExactList

/// Queries in the list's own coordinates: §5.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class GeometryTests: XCTestCase {

    /// `rect(ofRow:)`, `row(at:)` and `rows(in:)` against `ReferenceLayout`,
    /// shifted by the offset, at the top, in the middle and at the end, with
    /// spacing and insets, and out of range.
    func testG4_queries() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<200).map { 18 + CGFloat(($0 * 37) % 50) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        list.rowSpacing = 6
        list.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 30, right: 0)
        await stage.mount(list)

        // `W` is what the delegate was asked at (L7): the clip view's width,
        // which a legacy scroller narrows below the list's own.
        var widths = Set<CGFloat>()
        for case .heightOfRow(_, let width) in host.calls { widths.insert(width) }
        XCTAssertEqual(widths.count, 1, "heights asked at several widths: \(widths)")
        let width = try XCTUnwrap(widths.first)
        let frames = ReferenceLayout.frames(heights: heights, spacing: 6, width: width)
        for row in [0, 50, 150, heights.count - 1] {
            list.scrollToRow(row, at: .top)
            await stage.settle()
            // The document's top in the list's coordinates is where row 0 is.
            let shift = list.rect(ofRow: 0).minY - frames[0].minY
            for probe in [0, row, max(0, row - 1), min(heights.count - 1, row + 3), heights.count - 1] {
                let expected = frames[probe].offsetBy(dx: 0, dy: shift)
                XCTAssertEqual(list.rect(ofRow: probe), expected, "row \(probe) with row \(row) at the top")
                XCTAssertEqual(list.row(at: NSPoint(x: 5, y: expected.midY)), probe)
                XCTAssertEqual(list.row(at: NSPoint(x: 5, y: expected.maxY + 3)), -1, "a spacing gap is no row")
            }
            let span = NSRect(x: 0, y: frames[row].minY + shift + 1, width: width, height: 100)
            let expectedRange = frames.indices.filter { frames[$0].offsetBy(dx: 0, dy: shift).intersects(span) }
            XCTAssertEqual(list.rows(in: span), expectedRange.first!..<(expectedRange.last! + 1))
        }
        XCTAssertEqual(list.rect(ofRow: -1), .zero)
        XCTAssertEqual(list.rect(ofRow: heights.count), .zero)
        XCTAssertEqual(list.row(at: NSPoint(x: -5, y: 10)), -1)
    }

    /// Rows lie their own spacing apart, flush where a row asks for 0; the
    /// spacing is asked right after the height of every row the host
    /// announces (loading, a note, an insert), and never by a width change or
    /// a reload of a row's view.
    func testG7_eachRowItsOwnSpacingAskedWhenTheRowIsAnnounced() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = (0..<40).map { 20 + CGFloat(($0 * 13) % 30) }
        var customs: [CGFloat?] = heights.indices.map { [nil, 0, 6, nil][$0 % 4] }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        host.spacing = { customs[$0] }
        let list = ExactListView(dataSource: host, delegate: host)
        list.rowSpacing = 14
        await stage.mount(list)

        func pairs() -> [Int] {
            zip(host.calls, host.calls.dropFirst()).compactMap { call, next in
                guard case .heightOfRow(let row, _) = call, next == .customSpacingAboveRow(row) else { return nil }
                return row
            }
        }
        func spacingsAsked() -> [Int] {
            host.calls.compactMap { if case .customSpacingAboveRow(let row) = $0 { row } else { nil } }
        }
        XCTAssertEqual(pairs(), Array(heights.indices), "every row: its height, then its spacing")
        XCTAssertEqual(spacingsAsked(), Array(heights.indices))

        func assertFrames(_ message: String) {
            let width = list.rect(ofRow: 0).width
            let frames = ReferenceLayout.frames(heights: heights, spacing: 14, width: width, customs: customs)
            let shift = list.rect(ofRow: 0).minY
            for row in 0..<12 {
                XCTAssertEqual(list.rect(ofRow: row), frames[row].offsetBy(dx: 0, dy: shift), "row \(row), \(message)")
            }
        }
        assertFrames("as loaded")
        XCTAssertEqual(list.rect(ofRow: 1).minY, list.rect(ofRow: 0).maxY, "a row asking for 0 sits flush")
        XCTAssertEqual(list.row(at: NSPoint(x: 5, y: list.rect(ofRow: 2).minY - 3)), -1, "a gap is no row's")

        // A width change and a reload re-ask no spacing.
        host.resetCalls()
        await stage.setContentSize(NSSize(width: 300, height: 300))
        list.reloadData(forRowIndexes: [0, 1])
        await stage.settle()
        XCTAssertFalse(host.calls.isEmpty, "premise: the width change re-measured rows")
        XCTAssertEqual(spacingsAsked(), [], "a width change or a reload asked for a spacing")

        // A noted row is asked again, and moves only what its gap moves.
        host.resetCalls()
        customs[5] = 30
        let above = list.rect(ofRow: 4)
        list.noteHeightOfRows(withIndexesChanged: [5])
        await stage.settle()
        XCTAssertEqual(pairs(), [5])
        XCTAssertEqual(list.rect(ofRow: 4), above, "the row above moved")
        XCTAssertEqual(list.rect(ofRow: 5).minY - list.rect(ofRow: 4).maxY, 30)

        // An inserted row brings its own.
        host.resetCalls()
        heights.append(25)
        customs.append(0)
        host.count = heights.count
        list.insertRows(at: [heights.count - 1], withAnimation: [])
        await stage.settle()
        XCTAssertEqual(pairs(), [heights.count - 1])
        assertFrames("after a note and an insert")
    }
}

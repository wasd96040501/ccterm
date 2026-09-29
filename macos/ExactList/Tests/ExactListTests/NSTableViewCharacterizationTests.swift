import AppKit
import ExactListTestSupport
import XCTest

/// What `NSTableView` actually does, asserted on the OS the suite runs on. These
/// back every "Characterized" claim in `SPEC.md` §2. If one fails, AppKit
/// changed, and §2 has to change with it.
@MainActor
final class NSTableViewCharacterizationTests: XCTestCase {

    /// §2 Geometry: `reloadData()` over 10 000 rows asks for far fewer heights
    /// than there are rows, and the document height it reports before the reader
    /// scrolls differs from the sum of the heights.
    func testCharacterizesEstimatedGeometry() async throws {
        let stage = ListStage(size: NSSize(width: 480, height: 600))
        defer { stage.teardown() }
        let rows = 10_000
        let host = RecordingTableHost(count: rows) { row, _ in 20 + CGFloat(row % 7) * 30 }
        let table = host.makeTableView()
        _ = await stage.mountTable(table, layOutFirst: true)

        var asked = Set<Int>()
        for case .heightOfRow(let row, _) in host.calls { asked.insert(row) }
        let sum = (0..<rows).reduce(CGFloat(0)) { $0 + host.height($1, 0) }

        XCTAssertLessThan(asked.count, rows / 2, "NSTableView asked \(asked.count) of \(rows) heights")
        XCTAssertGreaterThan(
            abs(table.frame.height - sum), 1,
            "document height \(table.frame.height) equals the sum of the heights \(sum): nothing was estimated")
    }

    /// §2 Scroll position: with the viewport in the middle, inserting a row above
    /// it changes which row is at the top of the viewport.
    func testCharacterizesContentMovingOnInsertAbove() async throws {
        let stage = ListStage(size: NSSize(width: 480, height: 600))
        defer { stage.teardown() }
        let host = RecordingTableHost(count: 100) { _, _ in 40 }
        let table = host.makeTableView()
        let scroll = await stage.mountTable(table, layOutFirst: true)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 50).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        await stage.settle()
        let before = table.row(at: NSPoint(x: 1, y: scroll.documentVisibleRect.minY + 1))

        host.count += 1
        table.insertRows(at: [0], withAnimation: [])
        await stage.settle()
        let after = table.row(at: NSPoint(x: 1, y: scroll.documentVisibleRect.minY + 1))

        XCTAssertEqual(before, 50)
        // The offset stayed where it was, so the index at the top is unchanged,
        // and that index now names the row that used to be one above.
        XCTAssertEqual(
            after, before,
            "the row that was at the top (now row \(before + 1)) is at row \(after): the content did not move")
    }

    /// §2 Setup order: a table given its data source and reloaded before layout
    /// asks for heights while its width is still 0.
    func testCharacterizesMeasuringBeforeLayout() async throws {
        let stage = ListStage(size: NSSize(width: 480, height: 600))
        defer { stage.teardown() }
        let host = RecordingTableHost(count: 50) { _, _ in 40 }
        let table = host.makeTableView()
        _ = await stage.mountTable(table, layOutFirst: false)

        let finalWidth = try XCTUnwrap(table.tableColumns.first?.width)
        var widths: [CGFloat] = []
        for case .heightOfRow(_, let width) in host.calls { widths.append(width) }

        XCTAssertGreaterThan(finalWidth, 100)
        XCTAssertTrue(
            widths.contains { abs($0 - finalWidth) > 1 },
            "every height was asked at the final width \(finalWidth): \(Set(widths))")
    }
}

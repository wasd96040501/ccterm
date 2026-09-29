import ExactListTestSupport
import XCTest

@testable import ExactList

/// The same workloads against ExactList and `NSTableView`, `-O` only: §13.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class ExactListBenchmarks: XCTestCase {

    /// A step is AppKit's own scroll of the document (what a wheel ends in),
    /// then the layout and display it causes. 10 000 rows of mixed heights,
    /// stepped 40 pt at a time down and back; the median step is compared.
    func testB1_scrolling() async throws {
        let heights = Self.mixedHeights(10_000)
        let (list, listStage) = await mountList(heights)
        defer { listStage.teardown() }
        let (table, tableStage) = await mountTable(heights)
        defer { tableStage.teardown() }
        let document = try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first?.documentView)

        var listSteps: [Double] = []
        var tableSteps: [Double] = []
        for pass in 0..<2 {
            for step in 0..<600 {
                let y = CGFloat(pass == 0 ? step : 599 - step) * 40
                listSteps.append(Self.time(listStage) { document.scroll(NSPoint(x: 0, y: y)) })
                tableSteps.append(Self.time(tableStage) { table.scroll(NSPoint(x: 0, y: y)) })
            }
        }
        Self.report("B1 scroll step", list: listSteps, table: tableSteps)
        XCTAssertLessThanOrEqual(Self.median(listSteps), Self.median(tableSteps), "B1: a scroll step")
    }

    /// Each update with animation off in both (a duration-0 group), then the
    /// layout and display it causes: appending, inserting at the top, noting
    /// a visible row's height, removing a range in view. Medians compared per
    /// update.
    func testB2_updates() async throws {
        var heights = Self.mixedHeights(10_000)
        var tableHeights = heights
        let listHost = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: listHost, delegate: listHost)
        let listStage = ListStage(size: NSSize(width: 500, height: 400))
        defer { listStage.teardown() }
        await listStage.mount(list)
        list.scrollToRow(5000, at: .top)
        await listStage.settle()
        let tableHost = RecordingTableHost(count: tableHeights.count) { row, _ in tableHeights[row] }
        let table = tableHost.makeTableView()
        let tableStage = ListStage(size: NSSize(width: 500, height: 400))
        defer { tableStage.teardown() }
        _ = await tableStage.mountTable(table, layOutFirst: true)
        table.scrollRowToVisible(5000)
        table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 5000).minY))
        await tableStage.settle()

        func still(_ body: () -> Void) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                body()
            })
        }
        var listTimes: [String: [Double]] = [:]
        var tableTimes: [String: [Double]] = [:]
        for round in 0..<40 {
            let visible = list.rows(in: list.bounds).lowerBound + 3
            let tableVisible = table.rows(in: table.visibleRect).location + 3

            listTimes["append", default: []].append(
                Self.time(listStage) {
                    heights.append(30)
                    listHost.count = heights.count
                    still { list.insertRows(at: [heights.count - 1]) }
                })
            tableTimes["append", default: []].append(
                Self.time(tableStage) {
                    tableHeights.append(30)
                    tableHost.count = tableHeights.count
                    still { table.insertRows(at: [tableHeights.count - 1], withAnimation: []) }
                })

            listTimes["insert at top", default: []].append(
                Self.time(listStage) {
                    heights.insert(40, at: 0)
                    listHost.count = heights.count
                    still { list.insertRows(at: [0]) }
                })
            tableTimes["insert at top", default: []].append(
                Self.time(tableStage) {
                    tableHeights.insert(40, at: 0)
                    tableHost.count = tableHeights.count
                    still { table.insertRows(at: [0], withAnimation: []) }
                })

            listTimes["note a visible height", default: []].append(
                Self.time(listStage) {
                    heights[visible] = round.isMultiple(of: 2) ? 90 : 25
                    still { list.noteHeightOfRows(withIndexesChanged: [visible]) }
                })
            tableTimes["note a visible height", default: []].append(
                Self.time(tableStage) {
                    tableHeights[tableVisible] = round.isMultiple(of: 2) ? 90 : 25
                    still { table.noteHeightOfRows(withIndexesChanged: [tableVisible]) }
                })

            let range = visible..<visible + 20
            let tableRange = tableVisible..<tableVisible + 20
            listTimes["remove a range", default: []].append(
                Self.time(listStage) {
                    heights.removeSubrange(range)
                    listHost.count = heights.count
                    still { list.removeRows(at: IndexSet(integersIn: range)) }
                })
            tableTimes["remove a range", default: []].append(
                Self.time(tableStage) {
                    tableHeights.removeSubrange(tableRange)
                    tableHost.count = tableHeights.count
                    still { table.removeRows(at: IndexSet(integersIn: tableRange), withAnimation: []) }
                })
            listHost.resetCalls()
            tableHost.resetCalls()
        }
        for name in ["append", "insert at top", "note a visible height", "remove a range"] {
            let listed = listTimes[name] ?? []
            let tabled = tableTimes[name] ?? []
            Self.report("B2 \(name)", list: listed, table: tabled)
            XCTAssertLessThanOrEqual(Self.median(listed), Self.median(tabled), "B2: \(name)")
        }
    }

    /// Each frame of a drag is a width change, then its layout and display.
    /// Heights depend on the width. `NSTableView` re-measures only when told:
    /// its frame adds `noteHeightOfRows` of the visible rows. Widths sweep
    /// 360…640 pt and back, 2 pt a frame.
    func testB3_widthChanges() async throws {
        let wrapped: (Int, CGFloat) -> CGFloat = { row, width in 20 + CGFloat(row % 7) * 3 + 6000 / width }
        let listHost = RecordingHost(count: 10_000, height: wrapped)
        let list = ExactListView(dataSource: listHost, delegate: listHost)
        let listStage = ListStage(size: NSSize(width: 500, height: 400))
        defer { listStage.teardown() }
        await listStage.mount(list)
        list.scrollToRow(4000, at: .top)
        await listStage.settle()
        let tableHost = RecordingTableHost(count: 10_000, height: wrapped)
        let table = tableHost.makeTableView()
        let tableStage = ListStage(size: NSSize(width: 500, height: 400))
        defer { tableStage.teardown() }
        _ = await tableStage.mountTable(table, layOutFirst: true)
        table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 4000).minY))
        await tableStage.settle()

        let widths = Array(stride(from: 360, through: 640, by: 2)) + Array(stride(from: 638, through: 360, by: -2))
        var listFrames: [Double] = []
        var tableFrames: [Double] = []
        for width in widths.map({ CGFloat($0) }) {
            listFrames.append(
                Self.time(listStage) { listStage.window.setContentSize(NSSize(width: width, height: 400)) })
            tableFrames.append(
                Self.time(tableStage) {
                    tableStage.window.setContentSize(NSSize(width: width, height: 400))
                    tableStage.window.layoutIfNeeded()
                    let visible = table.rows(in: table.visibleRect)
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: Range(visible) ?? 0..<0))
                })
        }
        Self.report("B3 drag frame", list: listFrames, table: tableFrames)
        XCTAssertLessThanOrEqual(Self.median(listFrames), Self.median(tableFrames), "B3: a frame of a drag")
    }

    /// From creating the view to its first displayed frame, 10 000 rows: the
    /// list measures every row (G1); the table measures a few hundred and
    /// estimates the rest (§2). Gate: 1.2× the table.
    func testB4_loading() async throws {
        let heights = Self.mixedHeights(10_000)
        _ = await mountList(heights)  // lets AppKit settle once (ListStage)
        var listLoads: [Double] = []
        var tableLoads: [Double] = []
        for _ in 0..<9 {
            let listStage = ListStage(size: NSSize(width: 500, height: 400))
            let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
            listLoads.append(
                Self.time(listStage) {
                    let list = ExactListView(dataSource: host, delegate: host)
                    Self.fill(listStage.rootView, with: list)
                })
            XCTAssertEqual(host.calls.filter { if case .heightOfRow = $0 { true } else { false } }.count, 10_000)
            listStage.teardown()

            let tableStage = ListStage(size: NSSize(width: 500, height: 400))
            let tableHost = RecordingTableHost(count: heights.count) { row, _ in heights[row] }
            tableLoads.append(
                Self.time(tableStage) {
                    let table = tableHost.makeTableView()
                    let scroll = NSScrollView()
                    scroll.hasVerticalScroller = true
                    scroll.drawsBackground = false
                    scroll.automaticallyAdjustsContentInsets = false
                    scroll.documentView = table
                    Self.fill(tableStage.rootView, with: scroll)
                    tableStage.window.layoutIfNeeded()
                    table.reloadData()
                })
            XCTAssertTrue(tableHost.calls.contains(.numberOfRows), "the table loaded")
            tableStage.teardown()
        }
        Self.report("B4 load", list: listLoads, table: tableLoads)
        XCTAssertLessThanOrEqual(Self.median(listLoads), 1.2 * Self.median(tableLoads), "B4: 1.2× the table")
    }

    // MARK: - Helpers

    private static func mixedHeights(_ count: Int) -> [CGFloat] {
        (0..<count).map { 22 + CGFloat(($0 * 37) % 61) + CGFloat($0 % 3) * 0.5 }
    }

    private func mountList(_ heights: [CGFloat]) async -> (ExactListView, ListStage) {
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        let stage = ListStage(size: NSSize(width: 500, height: 400))
        await stage.mount(list)
        hosts.append(host)
        return (list, stage)
    }

    private func mountTable(_ heights: [CGFloat]) async -> (NSTableView, ListStage) {
        let host = RecordingTableHost(count: heights.count) { row, _ in heights[row] }
        let table = host.makeTableView()
        let stage = ListStage(size: NSSize(width: 500, height: 400))
        _ = await stage.mountTable(table, layOutFirst: true)
        hosts.append(host)
        return (table, stage)
    }

    /// Keeps each host alive as long as its view: views hold them weakly.
    private var hosts: [AnyObject] = []

    /// Seconds of main-thread time for `body` and the layout and display it
    /// leaves pending in `stage`'s window.
    private static func time(_ stage: ListStage, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        stage.window.layoutIfNeeded()
        stage.window.displayIfNeeded()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[sorted.count / 2]
    }

    private static func report(_ name: String, list: [Double], table: [Double]) {
        let format = { (value: Double) in String(format: "%.3f ms", value * 1000) }
        print("\(name): ExactList \(format(median(list))), NSTableView \(format(median(table)))")
    }

    private static func fill(_ container: NSView, with view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

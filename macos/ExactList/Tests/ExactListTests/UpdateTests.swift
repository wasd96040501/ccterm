import ExactListTestSupport
import XCTest

@testable import ExactList

/// Batches and commits: §7.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class UpdateTests: XCTestCase {

    /// Before an animated insert returns: the count and every query are
    /// final, the rows in `P` are mounted, and each mounted row is where its
    /// motion starts: the rows above as they were, the inserted ones opening
    /// at zero height under row 61, the rows below where they were. Once the
    /// motion ends, every mounted row is at its final frame.
    func testU1_synchronousCommit() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = (0..<200).map { 20 + CGFloat(($0 * 7) % 30) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(60, at: .top)
        await stage.settle()
        let offset = -list.rect(ofRow: 0).minY
        let width = list.rect(ofRow: 0).width
        let old = ReferenceLayout.frames(heights: heights, spacing: 0, width: width)

        heights.insert(contentsOf: [45, 35], at: 62)
        host.count = heights.count
        var done = false
        list.performBatchUpdates(
            anchoring: .scrollOffset, { $0.insertRows(at: [62, 63], withAnimation: .effectGap) },
            completionHandler: { done = $0 })

        XCTAssertEqual(list.numberOfRows, 202)
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: width)
        for row in [0, 61, 62, 63, 64, 201] {
            XCTAssertEqual(list.rect(ofRow: row), frames[row].offsetBy(dx: 0, dy: -offset), "row \(row)")
        }
        let inP = frames.indices.filter { frames[$0].maxY > offset - 150 && frames[$0].minY < offset + 450 }
        // Under Reduce Motion the motion's start is its end (M1).
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        var views: [(row: Int, view: NSView)] = []
        for row in inP {
            let view = try XCTUnwrap(list.view(atRow: row), "row \(row) in P is mounted")
            views.append((row, view))
            let start: CGRect =
                switch row {
                case _ where reduceMotion: frames[row]
                case ..<62: old[row]
                case 62, 63: CGRect(x: 0, y: old[61].maxY, width: width, height: 0)
                default: old[row - 2]
                }
            XCTAssertEqual(
                list.convert(view.bounds, from: view), start.offsetBy(dx: 0, dy: -offset),
                "row \(row) is at its motion's start")
        }
        _ = await stage.drain(until: { done }, timeout: 2)
        XCTAssertTrue(done)
        for (row, view) in views {
            XCTAssertEqual(list.convert(view.bounds, from: view), list.rect(ofRow: row), "row \(row) is final")
        }
    }

    /// The outermost call's anchoring applies to a nested batch, every
    /// completion runs once the outermost batch's animations end, and the proxy
    /// used after its closure traps (in the probe).
    func testU3_theBatchClosureReceivesAProxy() async throws {
        try assertTraps("U3-closed", naming: "U3")

        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 200) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(50, at: .top)
        await stage.settle()
        let before = list.rect(ofRow: 50)

        var completions: [(Bool, TimeInterval)] = []
        let start = Date()
        host.count += 2
        list.performBatchUpdates(
            anchoring: .scrollOffset,
            { updates in
                updates.insertRows(at: [0], withAnimation: .effectGap)
                list.performBatchUpdates(
                    anchoring: .row(80), { $0.insertRows(at: [0], withAnimation: .effectGap) },
                    completionHandler: { completions.append(($0, Date().timeIntervalSince(start))) })
            }, completionHandler: { completions.append(($0, Date().timeIntervalSince(start))) })

        XCTAssertEqual(list.rect(ofRow: 50), before, "the outer .scrollOffset held the offset, not .row(80)")
        XCTAssertEqual(completions.count, 0)
        let drained = await stage.drain(until: { completions.count == 2 }, timeout: 3)
        XCTAssertTrue(drained)
        for (finished, elapsed) in completions {
            XCTAssertTrue(finished)
            // Under Reduce Motion nothing animates (M1): only later than the call.
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertGreaterThanOrEqual(elapsed, 0.2 - 1.0 / 60, "after the 0.2 s animation, not before")
            }
        }
    }

    /// Each single call is a batch of one, anchored `.automatic`, with
    /// `NSTableView`'s index semantics: a moved row keeps its view, and the
    /// first visible row stays where it was through every call.
    func testU4_singleCalls() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = (0..<200).map { 20 + CGFloat(($0 * 7) % 30) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(80, at: .top)
        await stage.settle()

        // The first visible row, before and after each call's renumbering.
        func held(_ before: Int, _ after: Int, _ call: String, _ body: () -> Void) {
            let top = list.rect(ofRow: before).minY
            body()
            XCTAssertEqual(list.rect(ofRow: after).minY, top, "\(call): the first visible row held")
        }
        heights.insert(contentsOf: [30, 30, 30], at: 10)
        host.count = heights.count
        held(80, 83, "insertRows") { list.insertRows(at: [10, 11, 12]) }
        heights.removeSubrange(0..<5)
        host.count = heights.count
        held(83, 78, "removeRows") { list.removeRows(at: IndexSet(integersIn: 0..<5)) }

        // `to` is in the numbering after the removal, as in NSTableView.
        let moving = try XCTUnwrap(list.view(atRow: 82))
        heights.insert(heights.remove(at: 82), at: 86)
        held(78, 78, "moveRow") { list.moveRow(at: 82, to: 86) }
        XCTAssertTrue(list.view(atRow: 86) === moving, "the moved row keeps its view")
        let width = list.rect(ofRow: 0).width
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: width)
        let shift = list.rect(ofRow: 78).minY - frames[78].minY
        for row in 79...90 {
            XCTAssertEqual(list.rect(ofRow: row), frames[row].offsetBy(dx: 0, dy: shift), "row \(row) after the move")
        }

        heights[77] += 40
        held(78, 78, "noteHeightOfRows") { list.noteHeightOfRows(withIndexesChanged: [77]) }
        XCTAssertEqual(list.rect(ofRow: 77).height, heights[77])
        held(78, 78, "reloadData(forRowIndexes:)") { list.reloadData(forRowIndexes: [79]) }
        XCTAssertEqual(list.numberOfRows, heights.count)
    }

    /// No height is asked inside the closure. At commit: inserted and noted
    /// rows at `W`, and the stale rows the commit brings into `P`, measured at
    /// the current `W`, before the call returns.
    func testU5_whenHeightsAreAsked() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 3000) { row, width in 20 + CGFloat(row % 5) * 3 + 3000 / width }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)

        host.resetCalls()
        var callsInside = 0
        host.count += 1
        list.performBatchUpdates { updates in
            updates.insertRows(at: [3])
            updates.noteHeightOfRows(withIndexesChanged: [7])
            callsInside = host.calls.count
        }
        let width = list.rect(ofRow: 0).width
        XCTAssertEqual(callsInside, 0, "nothing is asked inside the closure")
        XCTAssertEqual(measured(host).sorted(), [3, 7])
        XCTAssertTrue(host.calls.allSatisfy { if case .heightOfRow(_, let w) = $0 { w == width } else { true } })
        await stage.settle()

        // A width change leaves the rows outside P stale until idle turns
        // refresh them; commit before any turn passes.
        stage.window.setContentSize(NSSize(width: 520, height: 300))
        stage.window.layoutIfNeeded()
        let newWidth = list.rect(ofRow: 0).width
        XCTAssertNotEqual(newWidth, width)
        host.resetCalls()
        host.count -= 60
        list.performBatchUpdates(anchoring: .scrollOffset) { $0.removeRows(at: IndexSet(integersIn: 0..<60)) }

        let asked = Set(measured(host))
        XCTAssertTrue(host.calls.allSatisfy { if case .heightOfRow(_, let w) = $0 { w == newWidth } else { true } })
        XCTAssertFalse(asked.isEmpty, "the rows that moved into P were stale")
        var mounted = Set<Int>()
        list.enumerateAvailableRowViews { _, row in mounted.insert(row) }
        XCTAssertTrue(asked.isSubset(of: mounted), "only rows the commit brought in were measured")
        // `rect(ofRow:)` is converted by AppKit, which can move a fractional
        // height in its last bits; the value asked for is exact.
        for row in mounted {
            XCTAssertEqual(
                list.rect(ofRow: row).height, host.height(row + 60, newWidth), accuracy: 1e-9, "row \(row) at the new W"
            )
        }
    }

    /// Only the mounted rows among the indexes are asked for views; no height
    /// is asked. A host recycling through `makeView` gets each row's own view
    /// back, and nothing is reported. A different instance replaces the old
    /// one, which is reported. A view handed back without the pool is not also
    /// left in it.
    func testU6_reloadingARowsContents() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 500) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let old2 = try XCTUnwrap(list.view(atRow: 2))
        let old3 = try XCTUnwrap(list.view(atRow: 3))
        let frame2 = list.rect(ofRow: 2)

        host.resetCalls()
        list.reloadData(forRowIndexes: [2, 3, 400])
        let views = host.calls.compactMap { if case .viewForRow(let row) = $0 { row } else { nil } }
        XCTAssertEqual(views.sorted(), [2, 3], "row 400 isn't mounted")
        XCTAssertEqual(measured(host), [], "heights are not asked")
        XCTAssertTrue(list.view(atRow: 2) === old2, "row 2 got its own view back")
        XCTAssertTrue(list.view(atRow: 3) === old3, "row 3 got its own view back")
        XCTAssertEqual(list.convert(old2.bounds, from: old2), frame2)
        let removed = host.calls.compactMap { if case .didRemove(let view, let row) = $0 { (view, row) } else { nil } }
        XCTAssertEqual(removed.count, 0, "no view left a row")

        // A host that builds a new view: it replaces the old one, which is
        // reported.
        let unpooled = UnpooledHost()
        let replacing = ExactListView(dataSource: unpooled, delegate: unpooled)
        stage.rootView.subviews.forEach { $0.removeFromSuperview() }
        await stage.mount(replacing)
        let before = try XCTUnwrap(replacing.view(atRow: 2))
        unpooled.makesFreshViews = true
        replacing.reloadData(forRowIndexes: [2])
        let after = try XCTUnwrap(replacing.view(atRow: 2))
        XCTAssertFalse(after === before)
        XCTAssertEqual(replacing.convert(after.bounds, from: after), replacing.rect(ofRow: 2))
        XCTAssertEqual(unpooled.removed.count, 1)
        XCTAssertTrue(unpooled.removed.first?.view === before && unpooled.removed.first?.row == 2)
        XCTAssertEqual(replacing.row(for: before), -1)

        // A host that hands the same view back without asking the pool: the
        // view isn't also left in the pool for the next row that arrives.
        unpooled.makesFreshViews = false
        let kept = try XCTUnwrap(replacing.view(atRow: 3))
        unpooled.kept = (row: 3, view: kept)
        replacing.reloadData(forRowIndexes: [3])
        unpooled.kept = nil
        unpooled.count += 1
        replacing.insertRows(at: [0])  // `[]` asks for no motion (M1)
        XCTAssertTrue(replacing.view(atRow: 4) === kept, "the kept view is row 3's, now row 4")
        XCTAssertFalse(replacing.view(atRow: 0) === kept, "the arriving row got another view")

        // A pooled view can still sit in a row's former container, hidden
        // (P3). Reloading hands it to a mounted row; containers reused later
        // must not take it back out of that row.
        var heights: [CGFloat] = Array(repeating: 30, count: 200)
        let poolHost = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let pooled = ExactListView(dataSource: poolHost, delegate: poolHost)
        stage.rootView.subviews.forEach { $0.removeFromSuperview() }
        await stage.mount(pooled)
        func still(_ body: () -> Void) {
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0
                body()
            }
        }
        heights[0] = 400  // rows below leave: their containers become spares
        still { pooled.noteHeightOfRows(withIndexesChanged: [0]) }
        still { pooled.reloadData(forRowIndexes: [1, 2, 3]) }
        heights[0] = 30  // rows arrive with none leaving: spares are reused
        still { pooled.noteHeightOfRows(withIndexesChanged: [0]) }
        pooled.enumerateAvailableRowViews { view, row in
            XCTAssertNotNil(view.window, "row \(row)'s view is in the window")
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "row \(row)'s view shows")
        }
        for row in pooled.rows(in: pooled.bounds) {
            XCTAssertNotNil(pooled.view(atRow: row)?.window, "row \(row) has its view")
        }
    }

    /// With a motion in flight: every motion stops, the pending completion
    /// gets `false`, every mounted view (the one animating out too) hears
    /// `didRemove`, the count and every height are asked again, and nothing
    /// moves.
    func testU7_reloadData() async throws {
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Reduce Motion is on: no motion is ever in flight (M1)")
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 100) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        var views: [ObjectIdentifier] = []
        list.enumerateAvailableRowViews { view, _ in views.append(ObjectIdentifier(view)) }

        var completions: [Bool] = []
        host.count -= 1
        list.performBatchUpdates(
            { $0.removeRows(at: [2], withAnimation: .effectGap) }, completionHandler: { completions.append($0) })
        XCTAssertTrue(try moving(list))
        // The rows that closed the gap brought a new row into P: it is in the
        // list now, beside row 2's view animating out.
        list.enumerateAvailableRowViews { view, _ in views.append(ObjectIdentifier(view)) }

        host.resetCalls()
        list.reloadData()
        XCTAssertEqual(completions, [], "not synchronously (U8)")
        XCTAssertFalse(try moving(list), "every motion stopped")
        list.enumerateAvailableRowViews { view, row in
            XCTAssertEqual(list.convert(view.bounds, from: view), list.rect(ofRow: row), "row \(row) is final")
        }
        let removed = Set(host.calls.compactMap { if case .didRemove(let view, _) = $0 { view } else { nil } })
        XCTAssertEqual(removed, Set(views), "every view that was in the list, including the one animating out")
        XCTAssertEqual(host.calls.filter { $0 == .numberOfRows }.count, 1)
        XCTAssertEqual(measured(host), Array(0..<99))
        var subviews = 0
        list.enumerateAvailableRowViews { _, _ in subviews += 1 }
        // Spares may stay in the document, hidden and in no row (P3).
        let showing = try internalDocument(of: list).subviews.filter { !$0.isHidden }
        XCTAssertEqual(showing.count, subviews, "nothing left behind")

        let drained = await stage.drain(until: { !completions.isEmpty }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertEqual(completions, [false])
        await stage.settle()
        XCTAssertEqual(completions, [false], "once")
    }

    /// Always later than the call, on the main thread: for an empty batch, a
    /// batch in a duration-0 group, one that asks for no motion, and an
    /// animated one only after it ends.
    func testU8_completionHandlers() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 100) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)

        var log: [String] = []
        list.performBatchUpdates({ _ in }, completionHandler: { log.append("empty \($0) \(Thread.isMainThread)") })
        host.count += 1
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0
                list.performBatchUpdates(
                    { $0.insertRows(at: [0]) }, completionHandler: { log.append("still \($0) \(Thread.isMainThread)") })
            }, completionHandler: nil)
        host.count += 1
        list.performBatchUpdates(
            { $0.insertRows(at: [0]) }, completionHandler: { log.append("plain \($0) \(Thread.isMainThread)") })
        XCTAssertEqual(log, [], "never before the call returns")
        await stage.settle()
        XCTAssertEqual(log, ["empty true true", "still true true", "plain true true"])

        host.count += 1
        let start = Date()
        var elapsed: TimeInterval?
        list.performBatchUpdates(
            anchoring: .scrollOffset, { $0.insertRows(at: [0], withAnimation: .effectGap) },
            completionHandler: { _ in elapsed = Date().timeIntervalSince(start) })
        // Under Reduce Motion it asks for motion and gets none (M1): only later
        // than the call.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        XCTAssertEqual(try moving(list), !reduceMotion)
        XCTAssertNil(elapsed, "never before the call returns")
        let drained = await stage.drain(until: { elapsed != nil }, timeout: 2)
        XCTAssertTrue(drained)
        if !reduceMotion {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(elapsed), 0.2 - 1.0 / 60, "after the 0.2 s animation ends")
        }
        XCTAssertFalse(try moving(list), "and nothing moves any more")
    }

    // MARK: - Helpers

    /// A host that can answer `viewForRow` without recycling: a new view every
    /// time, or a view it kept for one row.
    private final class UnpooledHost: ExactListViewDataSource, ExactListViewDelegate {
        var count = 500
        var makesFreshViews = false
        var kept: (row: Int, view: NSView)?
        private(set) var removed: [(view: NSView, row: Int)] = []

        func numberOfRows(in listView: ExactListView) -> Int { count }

        func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat { 30 }

        func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
            if let kept, kept.row == row { return kept.view }
            if makesFreshViews { return NSView() }
            return listView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("unpooled")) { NSView() }
        }

        func listView(_ listView: ExactListView, didRemove view: NSView, forRow row: Int) {
            removed.append((view, row))
        }
    }

    private func measured(_ host: RecordingHost) -> [Int] {
        host.calls.compactMap {
            if case .heightOfRow(let row, _) = $0 { return row }
            return nil
        }
    }

    private func internalDocument(of list: ExactListView) throws -> NSView {
        try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first?.documentView)
    }

    /// Whether a motion is running: a clock is ticking (M3), and no layer in
    /// the document carries a CoreAnimation animation either way.
    private func moving(_ list: ExactListView) throws -> Bool {
        let document = try internalDocument(of: list)
        var keys: [String] = []
        func walk(_ view: NSView) {
            keys += view.layer?.animationKeys() ?? []
            view.subviews.forEach(walk)
        }
        document.subviews.forEach(walk)
        XCTAssertEqual(keys, [], "no CoreAnimation animation")
        return document.subviews.contains { $0 is MotionClock }
    }

    private func assertTraps(_ scenario: String, naming id: String, line: UInt = #line) throws {
        let outcome = try ProbeRunner.run(scenario)
        XCTAssertTrue(outcome.trapped, "\(scenario) ended with status \(outcome.status)", line: line)
        XCTAssertTrue(outcome.standardError.contains("(\(id))"), "\(scenario): \(outcome.standardError)", line: line)
    }
}

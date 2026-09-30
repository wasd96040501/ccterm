import ExactListTestSupport
import XCTest

@testable import ExactList

/// The mounted set, views and reuse: §10.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class PlacementTests: XCTestCase {

    /// At rest after each way the offset moves (a scroll request, the wheel,
    /// `NSClipView.scroll(to:)`), and on every turn of an `animator()` scroll
    /// through `setBoundsOrigin`: the mounted rows are exactly `P`'s and
    /// AppKit's bounded overdraw, each at G1's frame. With insets, so the
    /// overdraw bound (the height of `U`) differs from `V`.
    func testP1_exactMounting() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 320))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<800).map { 18 + CGFloat(($0 * 29) % 47) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        let insets = NSEdgeInsets(top: 30, left: 0, bottom: 50, right: 0)
        list.contentInsets = insets
        await stage.mount(list)
        let scroll = try internalScrollView(of: list)
        let document = try XCTUnwrap(scroll.documentView)
        try assertExact(list, heights: heights, insets: insets, "at load")

        list.scrollToRow(300, at: .centeredVertically)
        await stage.settle()
        try assertExact(list, heights: heights, insets: insets, "after scrollToRow")

        document.scroll(NSPoint(x: 0, y: 9_000))
        try assertExact(list, heights: heights, insets: insets, "at once after NSClipView.scroll(to:)")
        await stage.settle()
        try assertExact(list, heights: heights, insets: insets, "settled after NSClipView.scroll(to:)")

        for _ in 0..<6 {
            EventSynthesizer.scroll(in: stage.window, at: NSPoint(x: 200, y: 160), deltaY: 170, phase: [])
            try assertExact(list, heights: heights, insets: insets, "at once after a wheel step")
        }
        await stage.settle()

        var turns = 0
        var done = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: 2_000))
        } completionHandler: {
            done = true
        }
        while !done {
            try assertExact(list, heights: heights, insets: insets, "during an animator() scroll")
            turns += 1
            _ = await stage.drain(until: { true }, timeout: 0)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        await stage.settle()
        XCTAssertGreaterThan(turns, 5, "sampled during the animation")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 2_000)
        try assertExact(list, heights: heights, insets: insets, "after an animator() scroll")

        // A host that builds every view anew, never through the pool, as a
        // table's host may: the rows still show, and nothing else does.
        let freshHost = FreshViewHost(heights: heights)
        let fresh = ExactListView(dataSource: freshHost, delegate: freshHost)
        fresh.contentInsets = insets
        stage.rootView.subviews.forEach { $0.removeFromSuperview() }
        await stage.mount(fresh)
        fresh.scrollToRow(300, at: .centeredVertically)
        await stage.settle()
        for step in 0..<6 {
            let deltaY: CGFloat = step < 3 ? 170 : -170
            EventSynthesizer.scroll(in: stage.window, at: NSPoint(x: 200, y: 160), deltaY: deltaY, phase: [])
            try assertExact(fresh, heights: heights, insets: insets, "fresh views, at once after a wheel step")
        }
    }

    /// Scrolling within `P` asks for nothing. Further, each arriving row is
    /// asked once, and only those; the list sizes every view to `W × h`.
    func testP2_viewsAreAskedForOnlyOnArrival() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<500).map { 20 + CGFloat(($0 * 13) % 40) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let document = try XCTUnwrap(internalScrollView(of: list).documentView)
        let mountedBefore = mountedRows(list)

        host.resetCalls()
        document.scroll(NSPoint(x: 0, y: 1))
        await stage.settle()
        let arrivedSmall = mountedRows(list).subtracting(mountedBefore)
        XCTAssertEqual(Set(askedViews(host)), arrivedSmall, "only rows that arrived")

        for offset in [CGFloat(600), 1_400, 1_450, 5_000, 300] {
            let before = mountedRows(list)
            host.resetCalls()
            document.scroll(NSPoint(x: 0, y: offset))
            await stage.settle()
            let asked = askedViews(host)
            XCTAssertEqual(asked.count, Set(asked).count, "once each, at \(offset)")
            XCTAssertEqual(Set(asked), mountedRows(list).subtracting(before), "exactly the arrivals, at \(offset)")
        }
        let width = list.rect(ofRow: 0).width
        list.enumerateAvailableRowViews { view, row in
            XCTAssertEqual(view.frame, NSRect(x: 0, y: 0, width: width, height: heights[row]), "row \(row)'s view")
        }
    }

    /// Every view that leaves hears `didRemove` exactly once, with its row;
    /// a removed row's view only after its animation, with −1 — at once under
    /// Reduce Motion, where nothing animates (M1).
    func testP3_didRemoveOnDeparture() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 1000) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        var before: [ObjectIdentifier: Int] = [:]
        list.enumerateAvailableRowViews { view, row in before[ObjectIdentifier(view)] = row }

        host.resetCalls()
        list.scrollToRow(600, at: .top)
        await stage.settle()
        let removed = host.calls.compactMap { if case .didRemove(let view, let row) = $0 { (view, row) } else { nil } }
        XCTAssertEqual(removed.count, before.count, "once each")
        for (view, row) in removed {
            XCTAssertEqual(before[view], row, "reported with the row it had")
        }

        let leaving = try XCTUnwrap(list.view(atRow: 605))
        host.resetCalls()
        host.count -= 1
        let start = Date()
        var landed = false
        list.performBatchUpdates(
            { $0.removeRows(at: [605], withAnimation: .effectGap) }, completionHandler: { _ in landed = true })
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        XCTAssertEqual(reported(leaving, in: host), reduceMotion, "not while it animates out")
        let drained = await stage.drain(until: { landed }, timeout: 2)
        XCTAssertTrue(drained)
        if !reduceMotion {
            // NSTableView's 0.2 s, less the frame AppKit's clock may end on.
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.2 - 1.0 / 60)
        }
        let departures = host.calls.compactMap {
            if case .didRemove(let view, let row) = $0, view == ObjectIdentifier(leaving) { row } else { nil }
        }
        XCTAssertEqual(departures, [-1], "once, after the animation, with row −1")
    }

    /// Scrolling through the list recycles a bounded set of views, all with
    /// the host's identifier; another identifier never gets one of them.
    func testP4_reuse() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 5000) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let document = try XCTUnwrap(internalScrollView(of: list).documentView)

        var seen = Set<ObjectIdentifier>()
        var mostMounted = 0
        for step in 1...60 {
            document.scroll(NSPoint(x: 0, y: CGFloat(step) * 2_000))
            await stage.settle()
            var mounted = 0
            list.enumerateAvailableRowViews { view, _ in
                seen.insert(ObjectIdentifier(view))
                mounted += 1
                XCTAssertEqual(view.identifier, NSUserInterfaceItemIdentifier("RecordingHost.row"))
            }
            mostMounted = max(mostMounted, mounted)
        }
        XCTAssertLessThanOrEqual(seen.count, mostMounted * 2, "60 screens of rows from a bounded set of views")

        let other = NSUserInterfaceItemIdentifier("PlacementTests.other")
        let fresh = list.makeView(withIdentifier: other) { NSTextField(labelWithString: "") }
        XCTAssertEqual(fresh.identifier, other, "make()'s result gets the identifier")
        XCTAssertFalse(seen.contains(ObjectIdentifier(fresh)), "not a pooled view of another identifier")
    }

    /// During an animated commit the motion and the clip are on the
    /// containers: a container below the noted row is at its motion's start
    /// (its end under Reduce Motion, M1), and clips; the host's views fill
    /// their containers and get no animation, mask, clip or opacity.
    func testP5_rowContainersAreInternal() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 200)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let document = try XCTUnwrap(internalScrollView(of: list).documentView)

        heights[3] = 90
        list.noteHeightOfRows(withIndexesChanged: [3])
        list.enumerateAvailableRowViews { view, row in
            XCTAssertFalse(view.superview === document, "row \(row)'s view sits in a container")
            XCTAssertEqual(view.frame, view.superview?.bounds, "row \(row)'s view fills its container")
            XCTAssertEqual(view.layer?.animationKeys() ?? [], [], "row \(row)'s view is never animated")
            XCTAssertNil(view.layer?.mask)
            XCTAssertFalse(view.layer?.masksToBounds ?? false, "the host's layer isn't clipped by the list")
            XCTAssertEqual(view.alphaValue, 1)
            XCTAssertEqual(view.superview?.layer?.masksToBounds, true, "row \(row)'s container clips")
        }
        let below = try XCTUnwrap(list.view(atRow: 5)?.superview)
        XCTAssertEqual(
            list.convert(below.bounds, from: below).minY,
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 5 * 30 + 60 : 5 * 30,
            "the container moves: at its start, 60 pt above")
        XCTAssertEqual(list.rect(ofRow: 5).minY, 5 * 30 + 60, "the row is final")
    }

    /// A mounted view and its descendants answer their row; anything else,
    /// and a view animating out, answers −1. Under Reduce Motion nothing
    /// animates out (M1): the removed row's view leaves at once, as P3 shows.
    func testP6_rowFor() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 100) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)

        let view = try XCTUnwrap(list.view(atRow: 4))
        let child = NSView()
        view.addSubview(child)
        XCTAssertEqual(list.row(for: view), 4)
        XCTAssertEqual(list.row(for: child), 4)
        XCTAssertEqual(list.row(for: NSView()), -1)
        XCTAssertEqual(list.row(for: list), -1)

        host.count -= 1
        list.removeRows(at: [2])
        XCTAssertEqual(list.row(for: child), 3, "renumbered with its row")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let leaving = try XCTUnwrap(list.view(atRow: 1))
        host.count -= 1
        list.removeRows(at: [1], withAnimation: .effectGap)
        XCTAssertNotNil(leaving.superview, "still animating out")
        XCTAssertEqual(list.row(for: leaving), -1)
    }

    /// A floating subview for `.horizontal` rides with the rows through a
    /// vertical scroll, and the scroll view clips it.
    func testP8_floatingSubviews() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 300) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let floating = NSView(frame: NSRect(x: 0, y: 60, width: 400, height: 900))
        list.addFloatingSubview(floating, for: .horizontal)
        let scroll = try XCTUnwrap(
            sequence(first: floating as NSView, next: \.superview).lazy.compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(scroll.superview === list, "in the list's own scroll view")
        XCTAssertTrue(scroll.clipsToBounds, "clipped to the viewport (L11)")
        let before = list.convert(floating.bounds, from: floating)

        EventSynthesizer.scroll(in: stage.window, at: NSPoint(x: 200, y: 150), deltaY: 90, phase: [])
        await stage.settle()
        XCTAssertEqual(-list.rect(ofRow: 0).minY, 90)
        XCTAssertEqual(
            list.convert(floating.bounds, from: floating), before.offsetBy(dx: 0, dy: -90), "rode with the rows")
    }

    /// An unmounted row has no view, and asking builds none.
    func testP7_onlyMountedViewsAreHandedOut() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 1000) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        host.resetCalls()
        XCTAssertNotNil(list.view(atRow: 0))
        XCTAssertNil(list.view(atRow: 700))
        XCTAssertNil(list.view(atRow: -1))
        XCTAssertNil(list.view(atRow: 1000))
        XCTAssertEqual(host.calls, [], "no view was made to answer")
        list.scrollToRow(700, at: .top)
        XCTAssertNotNil(list.view(atRow: 700))
        XCTAssertNil(list.view(atRow: 0))
    }

    // MARK: - Helpers

    private func internalScrollView(of list: ExactListView) throws -> NSScrollView {
        try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    private func mountedRows(_ list: ExactListView) -> Set<Int> {
        var rows = Set<Int>()
        list.enumerateAvailableRowViews { _, row in rows.insert(row) }
        return rows
    }

    private func askedViews(_ host: RecordingHost) -> [Int] {
        host.calls.compactMap { if case .viewForRow(let row) = $0 { row } else { nil } }
    }

    private func reported(_ view: NSView, in host: RecordingHost) -> Bool {
        host.calls.contains {
            if case .didRemove(let removed, _) = $0 { removed == ObjectIdentifier(view) } else { false }
        }
    }

    /// P1 against the live clip view: `P` from the clip's own bounds and the
    /// insets, AppKit's `preparedContentRect` bounded to `P` ± the height of
    /// `U`, and G1's frames from the test's heights.
    /// Answers every `viewForRow` with a new view, outside the pool.
    private final class FreshViewHost: ExactListViewDataSource, ExactListViewDelegate {

        let heights: [CGFloat]

        init(heights: [CGFloat]) {
            self.heights = heights
        }

        func numberOfRows(in listView: ExactListView) -> Int {
            heights.count
        }

        func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
            heights[row]
        }

        func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
            NSView()
        }
    }

    private func assertExact(
        _ list: ExactListView, heights: [CGFloat], insets: NSEdgeInsets, _ moment: String, line: UInt = #line
    ) throws {
        let scroll = try internalScrollView(of: list)
        let clip = scroll.contentView.bounds
        let visible = clip.height - insets.top - insets.bottom
        let top = clip.minY + insets.top - visible / 2
        let bottom = clip.maxY - insets.bottom + visible / 2
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: clip.width)
        func rows(_ lower: CGFloat, _ upper: CGFloat) -> Set<Int> {
            Set(frames.indices.filter { frames[$0].maxY > lower && frames[$0].minY < upper })
        }
        var expected = rows(top, bottom)
        let prepared = try XCTUnwrap(scroll.documentView).preparedContentRect
        let lower = max(prepared.minY, top - visible)
        let upper = min(prepared.maxY, bottom + visible)
        if lower < upper { expected.formUnion(rows(lower, upper)) }
        XCTAssertEqual(mountedRows(list), expected, "\(moment), offset \(clip.minY)", line: line)
        let document = try XCTUnwrap(scroll.documentView)
        var mounted = 0
        list.enumerateAvailableRowViews { view, row in
            XCTAssertEqual(
                document.convert(view.bounds, from: view), frames[row], "\(moment): row \(row)'s frame", line: line)
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "\(moment): row \(row) shows", line: line)
            mounted += 1
        }
        // Nothing else shows: spares may stay in the document, hidden (P3).
        let showing = document.subviews.filter { !$0.isHidden }
        XCTAssertEqual(showing.count, mounted, "\(moment): only the mounted rows show", line: line)
    }
}

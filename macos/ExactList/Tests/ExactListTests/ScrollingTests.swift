import ExactListTestSupport
import XCTest

@testable import ExactList

/// Scroll requests, scroll commits and reader scrolling: §11.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class ScrollingTests: XCTestCase {

    /// The least scroll into `U`, from the test's model, with and without
    /// insets. Beside a real `NSTableView` with the same heights: above, taller
    /// than the viewport, and clamped at the end, both land at the same offset;
    /// below, `NSTableView` scrolls past the least amount (the deviation S1
    /// records), and the list lands the row's bottom exactly on `U`'s.
    func testS1_scrollingToARow() async throws {
        var heights: [CGFloat] = (0..<200).map { 20 + CGFloat(($0 * 13) % 35) }
        heights[120] = 700
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)

        let tableStage = ListStage(size: NSSize(width: 400, height: 300))
        defer { tableStage.teardown() }
        let tableHost = RecordingTableHost(count: heights.count) { row, _ in heights[row] }
        let table = tableHost.makeTableView()
        let tableScroll = await tableStage.mountTable(table, layOutFirst: true)

        // (row, whether it lies below the viewport when asked)
        for (row, below) in [(60, true), (30, false), (32, false), (120, true), (150, true), (5, false), (199, true)] {
            list.scrollRowToVisible(row)
            await stage.settle()
            table.scrollRowToVisible(row)
            await tableStage.settle()
            let tableOffset = tableScroll.contentView.bounds.origin.y
            let tall = heights[row] > 300
            let clamped = row == heights.count - 1
            if below && !tall && !clamped {
                XCTAssertEqual(list.rect(ofRow: row).maxY, 300, "row \(row): its bottom exactly on U's")
                XCTAssertGreaterThan(tableOffset, offset(of: list), "row \(row): NSTableView scrolls past the least")
            } else {
                XCTAssertEqual(offset(of: list), tableOffset, "row \(row): where NSTableView lands")
            }
        }

        // With insets: the least scroll that brings the row fully into U.
        let insets = NSEdgeInsets(top: 25, left: 0, bottom: 45, right: 0)
        list.contentInsets = insets
        list.scrollToRow(0, at: .top)
        await stage.settle()
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        var o = offset(of: list)
        for row in [40, 20, 22, 120, 199, 0] {
            let top = frames[row].minY
            let bottom = frames[row].maxY
            let reach = 300 - insets.top - insets.bottom
            if bottom - top > reach || top < o + insets.top {
                o = top - insets.top
            } else if bottom > o + 300 - insets.bottom {
                o = bottom - 300 + insets.bottom
            }
            o = min(max(o, -insets.top), max(-insets.top, frames.last!.maxY - 300 + insets.bottom))
            list.scrollRowToVisible(row)
            await stage.settle()
            XCTAssertEqual(offset(of: list), o, "row \(row) with insets")
        }
    }

    /// Each position aligns the row to `U`, clamped; the last row at
    /// `.bottom` is exactly the tail.
    func testS2_scrollingToAPosition() async throws {
        let heights: [CGFloat] = (0..<200).map { 20 + CGFloat(($0 * 13) % 35) }
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        let insets = NSEdgeInsets(top: 25, left: 0, bottom: 45, right: 0)
        list.contentInsets = insets
        list.automaticallyFollowsTail = true
        await stage.mount(list)
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let minOffset = -insets.top
        let maxOffset = frames.last!.maxY - 300 + insets.bottom
        func clamp(_ o: CGFloat) -> CGFloat { min(max(o, minOffset), maxOffset) }

        let row = 90
        list.scrollToRow(row, at: .top)
        XCTAssertEqual(offset(of: list), clamp(frames[row].minY - insets.top), ".top")
        XCTAssertEqual(list.rect(ofRow: row).minY, insets.top)
        list.scrollToRow(row, at: .bottom)
        XCTAssertEqual(list.rect(ofRow: row).maxY, 300 - insets.bottom, ".bottom")
        list.scrollToRow(row, at: .centeredVertically)
        let middle = insets.top + (300 - insets.top - insets.bottom) / 2
        XCTAssertEqual(list.rect(ofRow: row).midY, middle, ".centeredVertically")

        list.scrollToRow(0, at: .bottom)
        XCTAssertEqual(offset(of: list), minOffset, "clamped to oMin")
        list.scrollToRow(199, at: .top)
        XCTAssertEqual(offset(of: list), maxOffset, "clamped to oMax")
        list.scrollToRow(40, at: .top)
        list.scrollToRow(199, at: .bottom)
        XCTAssertEqual(offset(of: list), maxOffset, "the last row at .bottom is the tail")
        XCTAssertTrue(list.isFollowingTail)

        list.scrollToRow(40, at: .top)
        let before = offset(of: list)
        list.scrollToRow(60, at: .nearestHorizontalEdge)
        XCTAssertEqual(list.rect(ofRow: 60).maxY, 300 - insets.bottom, ".nearestHorizontalEdge: below, to the bottom")
        list.scrollToRow(40, at: .nearestHorizontalEdge)
        XCTAssertEqual(list.rect(ofRow: 40).minY, insets.top, ".nearestHorizontalEdge: above, to the top")
        XCTAssertEqual(offset(of: list), before)
    }

    /// Without animation a scroll lands at once, and nothing moves. Animated
    /// (an implicit-animation group), the offset itself moves, sampled on
    /// every refresh: from where it was, never back, to the destination,
    /// through every offset on the way however far, mounting only the rows
    /// in view. A commit during the flight carries it along by its `Δ`; a
    /// scroll by the reader and `reloadData()` end it where it is; a second
    /// scroll replaces it from where it is.
    func testS3_scrolls() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 2000)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let scrollView = try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scrollView.documentView)
        func clocks() -> Int { document.subviews.filter { $0 is MotionClock }.count }
        func animated(_ duration: TimeInterval, _ body: () -> Void) {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = duration
                    context.allowsImplicitAnimation = true
                    body()
                }, completionHandler: nil)
        }
        /// The offset on every refresh: the document's presented top is `−o`.
        func offsets(for seconds: TimeInterval) async -> [CGFloat] {
            await PresentationSampler.record([document], in: list, for: seconds).compactMap {
                $0.frames[ObjectIdentifier(document)].map { -$0.minY }
            }
        }

        list.scrollToRow(20, at: .top)
        XCTAssertEqual(offset(of: list), 600, "without animation: at once")
        XCTAssertEqual(clocks(), 0, "nothing moves")

        // A short one: 600 to 720, never back, over several frames.
        animated(0.3) { list.scrollToRow(24, at: .top) }
        XCTAssertEqual(offset(of: list), 600, "it starts where it was")
        var seen = await offsets(for: 0.45)
        XCTAssertEqual(seen.last, 720, "it ends at the destination")
        XCTAssertGreaterThan(Set(seen.filter { $0 > 600 && $0 < 720 }).count, 10, "through the offsets between")
        XCTAssertEqual(seen, seen.sorted(), "never back")
        XCTAssertEqual(clocks(), 0)

        // A long one: every offset on the way, with only the rows in view
        // mounted.
        var mostMounted = 0
        animated(0.4) { list.scrollToRow(1500, at: .top) }
        seen = await PresentationSampler.record(in: list, for: 0.55) {
            mostMounted = max(
                mostMounted, document.subviews.filter { ($0 as? RowContainerView)?.isHidden == false }.count)
            return [document]
        }.compactMap { $0.frames[ObjectIdentifier(document)].map { -$0.minY } }
        XCTAssertEqual(seen.last, 45_000)
        XCTAssertEqual(seen, seen.sorted(), "never back")
        XCTAssertLessThan(
            zip(seen, seen.dropFirst()).map { $1 - $0 }.max() ?? .infinity, 45_000 / 4, "no jump: nothing is capped")
        XCTAssertLessThan(mostMounted, 40, "only the rows in view are mounted, never the 1480 on the way")
        XCTAssertEqual(
            scrollView.verticalScroller?.doubleValue ?? 0, 45_000 / (60_000 - 300), accuracy: 1e-3,
            "the scroller moved with it")

        // A commit during the flight moves the destination by its Δ: two rows
        // inserted above the viewport, held by the default anchor, add 60.
        list.scrollToRow(20, at: .top)
        animated(0.4) { list.scrollToRow(40, at: .top) }
        _ = await offsets(for: 0.1)
        heights.insert(contentsOf: [30, 30], at: 0)
        host.count = heights.count
        list.insertRows(at: [0, 1])
        seen = await offsets(for: 0.5)
        XCTAssertEqual(seen.last, 1260, "row 40, now 42, at the top")
        XCTAssertEqual(list.rect(ofRow: 42).minY, 0)

        // A scroll by the reader ends the flight where it is.
        list.scrollToRow(20, at: .top)
        animated(0.4) { list.scrollToRow(1000, at: .top) }
        _ = await offsets(for: 0.1)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1234))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(clocks(), 0, "the reader's scroll ended it")
        seen = await offsets(for: 0.4)
        XCTAssertEqual(Set(seen), [1234], "and it stays where the reader put it")

        // reloadData() ends it too.
        animated(0.4) { list.scrollToRow(1000, at: .top) }
        _ = await offsets(for: 0.1)
        list.reloadData()
        XCTAssertEqual(clocks(), 0, "reloadData() ended it")
        let stopped = offset(of: list)
        XCTAssertNotEqual(stopped, 30_000, "where it was, not the destination")
        seen = await offsets(for: 0.4)
        XCTAssertEqual(Set(seen), [stopped])

        // A second scroll replaces the first, from where it is.
        animated(0.4) { list.scrollToRow(1500, at: .top) }
        _ = await offsets(for: 0.1)
        let replacedAt = offset(of: list)
        XCTAssertGreaterThan(replacedAt, stopped)
        animated(0.3) { list.scrollToRow(10, at: .top) }
        XCTAssertEqual(offset(of: list), replacedAt, "it starts where the first one was")
        seen = await offsets(for: 0.45)
        XCTAssertEqual(seen.last, 300)
        XCTAssertEqual(seen, seen.sorted(by: >), "straight back, never on towards the first destination")
        XCTAssertEqual(clocks(), 0, "one clock, ended")
    }

    /// The wheel moves the offset through `NSScrollView` itself, with its own
    /// elasticity. A commit between wheel steps shifts the offset as §6 says,
    /// and the next step goes on from there. A live trackpad gesture can't be
    /// synthesized in process (§13); it is the demo's to check.
    func testS4_readerScrollingStaysNative() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 400)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let point = NSPoint(x: 200, y: 150)
        let scroll = try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(scroll.verticalScrollElasticity, NSScrollView().verticalScrollElasticity)

        EventSynthesizer.scroll(in: stage.window, at: point, deltaY: 90, phase: [])
        await stage.settle()
        XCTAssertEqual(offset(of: list), 90, "a wheel step")

        heights.insert(40, at: 0)
        host.count = heights.count
        list.insertRows(at: [0])
        XCTAssertEqual(offset(of: list), 130, "the first visible row held")

        EventSynthesizer.scroll(in: stage.window, at: point, deltaY: 60, phase: [])
        await stage.settle()
        XCTAssertEqual(offset(of: list), 190, "the next step went on from the adjusted offset")

        EventSynthesizer.scroll(in: stage.window, at: point, deltaY: -500, phase: [])
        await stage.settle()
        XCTAssertEqual(offset(of: list), 0, "and the wheel stops at the top, as NSScrollView's")
    }

    // MARK: - Helpers

    /// `o`: row 0's top is at `−o` in the list's coordinates.
    private func offset(of list: ExactListView) -> CGFloat {
        -list.rect(ofRow: 0).minY
    }
}

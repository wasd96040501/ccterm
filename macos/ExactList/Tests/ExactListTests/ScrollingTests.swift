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

    /// The destination is final at once. Animated (an implicit-animation
    /// group), every moving container carries the same additive `position.y`
    /// from `δ`, and a long jump's `δ` is capped at the height of `U` (M7).
    /// Outside such a group nothing animates.
    func testS3_scrollsAreCommits() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 2000) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)

        list.scrollToRow(20, at: .top)
        XCTAssertEqual(offset(of: list), 600)
        XCTAssertEqual(positionDeltas(list), [], "no implicit animation, no motion")

        NSAnimationContext.runAnimationGroup(
            { context in
                context.allowsImplicitAnimation = true
                list.scrollToRow(24, at: .top)
            }, completionHandler: nil)
        XCTAssertEqual(offset(of: list), 720, "final at once (U1)")
        XCTAssertEqual(Set(positionDeltas(list)), [120], "a uniform δ: rows start 120 pt lower")
        await stage.settle()
        _ = await stage.drain(until: { self.positionDeltas(list).isEmpty }, timeout: 1)

        NSAnimationContext.runAnimationGroup(
            { context in
                context.allowsImplicitAnimation = true
                list.scrollToRow(1500, at: .top)
            }, completionHandler: nil)
        XCTAssertEqual(offset(of: list), 45_000)
        XCTAssertEqual(Set(positionDeltas(list)), [300], "capped at the height of U")
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

    /// The `fromValue` of every mounted container's additive `position.y`
    /// animation (M3), which is `start − end` of its screen top.
    private func positionDeltas(_ list: ExactListView) -> [CGFloat] {
        var deltas: [CGFloat] = []
        list.enumerateAvailableRowViews { view, _ in
            guard let layer = view.superview?.layer else { return }
            for key in layer.animationKeys() ?? [] where key.hasSuffix("position.y") {
                if let animation = layer.animation(forKey: key) as? CABasicAnimation,
                    let from = animation.fromValue as? CGFloat
                {
                    deltas.append(from)
                }
            }
        }
        return deltas
    }
}

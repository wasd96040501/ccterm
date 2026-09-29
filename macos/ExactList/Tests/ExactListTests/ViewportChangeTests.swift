import ExactListTestSupport
import XCTest

@testable import ExactList

/// Viewport height, insets, spacing and the settings before loading: §6.4.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class ViewportChangeTests: XCTestCase {

    /// A window resize holds the first visible row at its distance from the top
    /// of `U`, as resolved before the resize; at the tail, the tail holds. No
    /// height is asked (the width didn't change) and nothing animates.
    func testV1_viewportHeight() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<150).map { 22 + CGFloat(($0 * 17) % 31) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        list.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        await stage.mount(list)
        try await scroll(list, toOffset: 813, stage: stage)

        let (anchor, distance) = firstVisible(list, heights: heights, top: 10)
        host.resetCalls()
        await stage.setContentSize(NSSize(width: 400, height: 460))
        XCTAssertEqual(list.bounds.height, 460)
        XCTAssertEqual(list.rect(ofRow: anchor).minY - 10, distance, "row \(anchor) held")
        XCTAssertEqual(measured(host), [], "the width didn't change")
        XCTAssertEqual(mountedAnimationKeys(list), [], "the resize is the motion")
        await stage.setContentSize(NSSize(width: 400, height: 220))
        XCTAssertEqual(list.rect(ofRow: anchor).minY - 10, distance, "and on the way down")

        list.automaticallyFollowsTail = true
        list.scrollRowToVisible(heights.count - 1)
        await stage.settle()
        XCTAssertTrue(list.isFollowingTail)
        for height in [CGFloat(380), 260, 500] {
            await stage.setContentSize(NSSize(width: 400, height: height))
            XCTAssertEqual(list.rect(ofRow: heights.count - 1).maxY, height, "the tail holds at V = \(height)")
            XCTAssertTrue(list.isFollowingTail)
        }
    }

    /// Insets work as V1: a growing bottom inset lifts the last row while
    /// following the tail; otherwise the first visible row keeps its distance
    /// from the top of `U`, resolved against the old insets.
    func testV2_contentInsets() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<150).map { 22 + CGFloat(($0 * 17) % 31) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        list.automaticallyFollowsTail = true
        await stage.mount(list)
        let last = heights.count - 1
        XCTAssertEqual(list.rect(ofRow: last).maxY, 300)

        list.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 64, right: 0)
        await stage.settle()
        XCTAssertEqual(list.rect(ofRow: last).maxY, 300 - 64, "the floating bar lifts the last row")
        XCTAssertTrue(list.isFollowingTail)

        list.automaticallyFollowsTail = false
        try await scroll(list, toOffset: 900, stage: stage)
        let (anchor, distance) = firstVisible(list, heights: heights, top: 0)
        host.resetCalls()
        list.contentInsets = NSEdgeInsets(top: 36, left: 0, bottom: 64, right: 0)
        await stage.settle()
        XCTAssertEqual(list.rect(ofRow: anchor).minY - 36, distance, "row \(anchor) held below the new top inset")
        XCTAssertEqual(measured(host), [])
        XCTAssertEqual(mountedAnimationKeys(list), [])
    }

    /// Spacing is a geometry commit: no height asked, the first visible row
    /// held, every frame G1's with the new `s`, nothing animated.
    func testV3_rowSpacing() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<150).map { 22 + CGFloat(($0 * 17) % 31) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        try await scroll(list, toOffset: 1200, stage: stage)
        let (anchor, distance) = firstVisible(list, heights: heights, top: 0)

        host.resetCalls()
        list.rowSpacing = 9
        XCTAssertEqual(measured(host), [], "no height is asked")
        XCTAssertEqual(list.rect(ofRow: anchor).minY, distance, "row \(anchor) held")
        let frames = ReferenceLayout.frames(heights: heights, spacing: 9, width: list.rect(ofRow: 0).width)
        let shift = list.rect(ofRow: anchor).minY - frames[anchor].minY
        for row in [0, anchor - 1, anchor + 1, 149] {
            XCTAssertEqual(list.rect(ofRow: row), frames[row].offsetBy(dx: 0, dy: shift), "row \(row)")
        }
        XCTAssertEqual(mountedAnimationKeys(list), [], "never animated")
        var mounted: [Int: NSRect] = [:]
        list.enumerateAvailableRowViews { view, row in mounted[row] = list.convert(view.bounds, from: view) }
        for (row, frame) in mounted {
            XCTAssertEqual(frame, list.rect(ofRow: row), "mounted row \(row) is at its frame")
        }
    }

    /// Toggling moves nothing; it re-evaluates A8 and reports only a change.
    func testV4_turningTailFollowingOnOrOff() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 100) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollRowToVisible(99)
        await stage.settle()
        let atTail = list.rect(ofRow: 99)
        XCTAssertFalse(list.isFollowingTail, "at the tail, but not following")

        list.automaticallyFollowsTail = true
        XCTAssertTrue(list.isFollowingTail)
        list.automaticallyFollowsTail = false
        XCTAssertFalse(list.isFollowingTail)
        XCTAssertEqual(list.rect(ofRow: 99), atTail, "nothing moved")
        XCTAssertEqual(tailReports(host), [true, false])

        list.scrollToRow(10, at: .top)
        await stage.settle()
        let away = list.rect(ofRow: 10)
        list.automaticallyFollowsTail = true
        XCTAssertFalse(list.isFollowingTail, "on, but not at the tail")
        XCTAssertEqual(list.rect(ofRow: 10), away, "turning it on doesn't scroll")
        XCTAssertEqual(tailReports(host), [true, false], "no change, no report")
    }

    /// All three set before the load point are what the load uses.
    func testV5_settingsBeforeLoading() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<80).map { 20 + CGFloat($0 % 4) * 10 }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        list.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 40, right: 0)
        list.rowSpacing = 5
        list.automaticallyFollowsTail = true
        XCTAssertEqual(list.rowSpacing, 5)
        XCTAssertEqual(list.contentInsets.bottom, 40)
        XCTAssertTrue(list.automaticallyFollowsTail)
        XCTAssertEqual(host.calls, [])

        await stage.mount(list)
        XCTAssertTrue(list.isFollowingTail)
        XCTAssertEqual(list.rect(ofRow: 79).maxY, 300 - 40, "the tail, above the bottom inset")
        let frames = ReferenceLayout.frames(heights: heights, spacing: 5, width: list.rect(ofRow: 0).width)
        let shift = list.rect(ofRow: 79).minY - frames[79].minY
        XCTAssertEqual(list.rect(ofRow: 40), frames[40].offsetBy(dx: 0, dy: shift), "spaced by 5")
        XCTAssertEqual(try internalScrollView(of: list).contentInsets.top, 12)
    }

    // MARK: - Helpers

    private func internalScrollView(of list: ExactListView) throws -> NSScrollView {
        try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    /// Moves the offset through AppKit's own route (`NSClipView.scroll(to:)`).
    private func scroll(_ list: ExactListView, toOffset offset: CGFloat, stage: ListStage) async throws {
        let document = try XCTUnwrap(internalScrollView(of: list).documentView)
        document.scroll(NSPoint(x: 0, y: offset))
        await stage.settle()
        XCTAssertEqual(-list.rect(ofRow: 0).minY, offset)
    }

    /// A1's first visible row and its distance, from the test's own heights
    /// and the offset read off row 0.
    private func firstVisible(_ list: ExactListView, heights: [CGFloat], top: CGFloat) -> (Int, CGFloat) {
        let offset = -list.rect(ofRow: 0).minY
        let frames = ReferenceLayout.frames(heights: heights, spacing: list.rowSpacing, width: 1)
        let row = frames.firstIndex { $0.maxY > offset + top }!
        return (row, frames[row].minY - (offset + top))
    }

    private func measured(_ host: RecordingHost) -> [Int] {
        host.calls.compactMap {
            if case .heightOfRow(let row, _) = $0 { return row }
            return nil
        }
    }

    private func tailReports(_ host: RecordingHost) -> [Bool] {
        host.calls.compactMap {
            if case .didChangeTailFollowing(let value) = $0 { return value }
            return nil
        }
    }

    /// Everything moving: a motion clock (M3), a CoreAnimation animation on a
    /// mounted row's view or container, or a mounted row away from its frame.
    private func mountedAnimationKeys(_ list: ExactListView) -> [String] {
        var keys: [String] = []
        let document = list.subviews.compactMap { $0 as? NSScrollView }.first?.documentView
        keys += (document?.subviews ?? []).filter { $0 is MotionClock }.map { _ in "clock" }
        list.enumerateAvailableRowViews { view, row in
            keys += view.layer?.animationKeys() ?? []
            keys += view.superview?.layer?.animationKeys() ?? []
            if list.convert(view.bounds, from: view) != list.rect(ofRow: row) { keys.append("row \(row) moving") }
        }
        return keys
    }
}

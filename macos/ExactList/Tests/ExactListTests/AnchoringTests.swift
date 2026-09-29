import ExactListTestSupport
import XCTest

@testable import ExactList

/// Tail following and reload anchoring, in a window: §6.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class AnchoringTests: XCTestCase {

    /// Following is a function of where the viewport is, whichever route put
    /// it there: a scroll request, AppKit's own scroll, or content shrinking
    /// under it. Within ε = 1 pt of `oMax` counts; beyond does not. The
    /// delegate hears each change once, and nothing at the load point.
    func testA8_tailFollowingDependsOnlyOnPosition() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = (0..<120).map { 20 + CGFloat(($0 * 11) % 25) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        list.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 16, right: 0)
        list.automaticallyFollowsTail = true
        await stage.mount(list)
        XCTAssertTrue(list.isFollowingTail, "loaded at the tail (L6)")
        XCTAssertEqual(tailReports(host), [], "nothing reported at the load point")

        // Rows arriving while at the tail keep the last row at the bottom of U.
        heights += [44, 60]
        host.count = heights.count
        list.insertRows(at: [120, 121])
        await stage.settle()
        XCTAssertEqual(list.rect(ofRow: 121).maxY, list.bounds.height - 16)
        XCTAssertTrue(list.isFollowingTail)

        // A scroll request away from the tail.
        list.scrollToRow(30, at: .top)
        await stage.settle()
        XCTAssertFalse(list.isFollowingTail)
        XCTAssertEqual(tailReports(host), [false])

        // Rows arriving now don't pull the viewport along.
        let before = list.rect(ofRow: 30)
        heights.append(50)
        host.count = heights.count
        list.insertRows(at: [heights.count - 1])
        await stage.settle()
        XCTAssertEqual(list.rect(ofRow: 30), before)
        XCTAssertFalse(list.isFollowingTail)

        // AppKit's own scroll route, to within ε of the tail, and just beyond.
        let document = try XCTUnwrap(internalScrollView(of: list).documentView)
        let maxOffset = maxOffset(of: list, contentHeight: contentHeight(heights), bottomInset: 16)
        document.scroll(NSPoint(x: 0, y: maxOffset - 0.5))
        await stage.settle()
        XCTAssertTrue(list.isFollowingTail, "within ε = 1 pt of oMax")
        document.scroll(NSPoint(x: 0, y: maxOffset - 2))
        await stage.settle()
        XCTAssertFalse(list.isFollowingTail, "2 pt above oMax is not the tail")
        XCTAssertEqual(tailReports(host), [false, true, false])

        // Content shrinking under the viewport puts it at the tail: no flag
        // remembers how it left.
        heights.removeLast(40)
        host.count = heights.count
        list.removeRows(at: IndexSet(integersIn: heights.count..<(heights.count + 40)))
        await stage.settle()
        XCTAssertTrue(list.isFollowingTail)
        XCTAssertEqual(list.rect(ofRow: heights.count - 1).maxY, list.bounds.height - 16)
        XCTAssertEqual(tailReports(host), [false, true, false, true])
    }

    /// Following: the new content's end sits at the bottom of `U`. Not
    /// following: the offset holds, clamped when the content shrank. Never
    /// animated.
    func testA9_reloadData() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = (0..<100).map { 24 + CGFloat($0 % 6) * 5 }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        list.automaticallyFollowsTail = true
        await stage.mount(list)
        XCTAssertTrue(list.isFollowingTail)

        heights = (0..<150).map { 18 + CGFloat($0 % 9) * 7 }
        host.count = heights.count
        list.reloadData()
        XCTAssertEqual(list.rect(ofRow: 149).maxY, list.bounds.height, "the tail, of the new content")
        XCTAssertEqual(mountedAnimationKeys(list), [], "never animated")

        list.scrollToRow(40, at: .top)
        await stage.settle()
        XCTAssertFalse(list.isFollowingTail)
        let offset = -list.rect(ofRow: 0).minY
        XCTAssertGreaterThan(offset, 0)

        // Different rows entirely: only the offset carries over.
        heights = (0..<150).map { 30 + CGFloat(($0 * 7) % 20) }
        list.reloadData()
        XCTAssertEqual(-list.rect(ofRow: 0).minY, offset, "the offset holds")
        let width = list.rect(ofRow: 0).width
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: width)
        XCTAssertEqual(list.rect(ofRow: 77), frames[77].offsetBy(dx: 0, dy: -offset))
        XCTAssertEqual(mountedAnimationKeys(list), [])

        // Shrunk below the offset: clamped to the new oMax.
        heights = Array(heights.prefix(12))
        host.count = heights.count
        list.reloadData()
        XCTAssertEqual(list.rect(ofRow: 11).maxY, list.bounds.height, "clamped to oMax")
    }

    // MARK: - Helpers

    private func tailReports(_ host: RecordingHost) -> [Bool] {
        host.calls.compactMap {
            if case .didChangeTailFollowing(let value) = $0 { return value }
            return nil
        }
    }

    private func internalScrollView(of list: ExactListView) throws -> NSScrollView {
        try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    private func contentHeight(_ heights: [CGFloat]) -> CGFloat {
        ReferenceLayout.contentHeight(heights: heights, spacing: 0)
    }

    /// `oMax = H + b − V` (G3), from the test's own heights.
    private func maxOffset(of list: ExactListView, contentHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        contentHeight + bottomInset - list.bounds.height
    }

    /// Animation keys on every mounted row's view and container.
    private func mountedAnimationKeys(_ list: ExactListView) -> [String] {
        var keys: [String] = []
        list.enumerateAvailableRowViews { view, _ in
            keys += view.layer?.animationKeys() ?? []
            keys += view.superview?.layer?.animationKeys() ?? []
        }
        return keys
    }
}

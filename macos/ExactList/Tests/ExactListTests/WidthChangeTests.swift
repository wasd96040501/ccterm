import ExactListTestSupport
import XCTest

@testable import ExactList

/// Width changes: §9. Heights here depend on the width, as wrapped text does.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class WidthChangeTests: XCTestCase {

    /// A window resize and a split divider, checked synchronously right after
    /// the layout pass that changes the width; and an `animator()` divider,
    /// checked on every run loop turn while it moves. At every check, every
    /// mounted row is at the current `W` and at its height for that `W`.
    func testW1_handledInTheSamePass() async throws {
        let stage = ListStage(size: NSSize(width: 700, height: 320))
        defer { stage.teardown() }
        let host = RecordingHost(count: 2000, height: Self.wrapped)
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mountInSplit(list, leftWidth: 200)
        list.scrollToRow(700, at: .top)
        await stage.settle()

        XCTAssertEqual(try unfresh(list, host), [], "at load")
        stage.window.setContentSize(NSSize(width: 760, height: 320))
        stage.window.layoutIfNeeded()
        XCTAssertEqual(try unfresh(list, host), [], "in the pass that resized the window")
        await stage.moveDivider(to: 260, animated: false)
        XCTAssertEqual(try unfresh(list, host), [], "after a divider move")

        var failures: [String] = []
        var widths = Set<CGFloat>()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let failure = try? self.unfresh(list, host), !failure.isEmpty {
                    failures.append("W \(list.rect(ofRow: 700).width): rows \(failure)")
                }
                widths.insert(list.rect(ofRow: 700).width)
                try? await Task.sleep(nanoseconds: 3_000_000)
            }
        }
        await stage.moveDivider(to: 60, animated: true)
        await stage.moveDivider(to: 380, animated: true)
        sampler.cancel()
        _ = await sampler.value
        XCTAssertGreaterThan(widths.count, 8, "sampled across the animation: \(widths.count) widths")
        XCTAssertEqual(failures, [], "a row was shown at a width it wasn't measured for")
    }

    /// Straight after the pass: the rows in `P` are at the new `W`, the rows
    /// far away keep their last height (stale), and the geometry is G1 over
    /// exactly those heights. Idle turns then bring every row to the new `W`
    /// (W5), and `H` is exact.
    func testW3_exactInThePreparedArea() async throws {
        let stage = ListStage(size: NSSize(width: 500, height: 320))
        defer { stage.teardown() }
        let host = RecordingHost(count: 3000, height: Self.wrapped)
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(1000, at: .top)
        await stage.settle()
        let oldWidth = list.rect(ofRow: 0).width

        stage.window.setContentSize(NSSize(width: 380, height: 320))
        stage.window.layoutIfNeeded()
        let width = list.rect(ofRow: 0).width
        XCTAssertNotEqual(width, oldWidth)
        let scroll = try internalScrollView(of: list)
        let clip = scroll.contentView.bounds
        let rowsInP = list.rows(in: NSRect(x: 0, y: -clip.height / 2, width: width, height: clip.height * 2))
        XCTAssertFalse(rowsInP.isEmpty)
        for row in rowsInP {
            XCTAssertEqual(list.rect(ofRow: row).height, Self.wrapped(row, width), accuracy: 1e-9, "row \(row) in P")
        }
        for row in [0, 10, 2500, 2999] {
            XCTAssertEqual(
                list.rect(ofRow: row).height, Self.wrapped(row, oldWidth), accuracy: 1e-9, "row \(row) stale")
        }
        let heights = (0..<3000).map { list.rect(ofRow: $0).height }
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: width)
        let shift = list.rect(ofRow: 1000).minY - frames[1000].minY
        XCTAssertEqual(list.rect(ofRow: 2999).maxY, frames[2999].maxY + shift, accuracy: 1e-6, "G1 over those")

        let refreshed = await stage.drain(
            until: { (0..<3000).allSatisfy { abs(list.rect(ofRow: $0).height - Self.wrapped($0, width)) < 1e-9 } },
            timeout: 5)
        XCTAssertTrue(refreshed, "idle turns refresh every stale row (W5)")
        let fresh = (0..<3000).map { Self.wrapped($0, width) }
        XCTAssertEqual(
            try XCTUnwrap(scroll.documentView).frame.height,
            ReferenceLayout.contentHeight(heights: fresh, spacing: 0), accuracy: 1e-6, "H exact again")
    }

    /// Before any turn lets refreshing run, stale rows are brought into `P`
    /// by a scroll request, by AppKit's scroll, by a commit, and by a second
    /// width change. Each arrives measured at the current `W`.
    func testW4_noStaleRowIsEverDisplayed() async throws {
        let stage = ListStage(size: NSSize(width: 500, height: 320))
        defer { stage.teardown() }
        let host = RecordingHost(count: 3000, height: Self.wrapped)
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let document = try XCTUnwrap(internalScrollView(of: list).documentView)

        stage.window.setContentSize(NSSize(width: 420, height: 320))
        stage.window.layoutIfNeeded()
        list.scrollToRow(1500, at: .top)
        XCTAssertEqual(try unfresh(list, host), [], "after a scroll request")

        document.scroll(NSPoint(x: 0, y: list.rect(ofRow: 2200).minY - list.rect(ofRow: 0).minY))
        XCTAssertEqual(try unfresh(list, host), [], "after NSClipView.scroll(to:)")

        host.count -= 300
        list.performBatchUpdates(anchoring: .scrollOffset) { list.removeRows(at: IndexSet(integersIn: 1800..<2100)) }
        XCTAssertEqual(try unfresh(list, host), [], "after a commit that pulls rows up")

        stage.window.setContentSize(NSSize(width: 560, height: 320))
        stage.window.layoutIfNeeded()
        XCTAssertEqual(try unfresh(list, host), [], "after a second width change")
        list.scrollToRow(20, at: .top)
        XCTAssertEqual(try unfresh(list, host), [], "back where the first change left rows stale")
    }

    /// Through loads, width changes, scrolls, refreshing and updates: a row
    /// is asked again at the width it was last measured at only if it was
    /// inserted, noted or reloaded since.
    func testW6_neverTwiceAtTheSameWidth() async throws {
        let stage = ListStage(size: NSSize(width: 700, height: 320))
        defer { stage.teardown() }
        let host = RecordingHost(count: 1500, height: Self.wrapped)
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mountInSplit(list, leftWidth: 200)
        var excused = Set<Int>()
        var last: [Int: CGFloat] = [:]
        var repeats: [String] = []
        func audit() {
            for call in host.calls {
                guard case .heightOfRow(let row, let width) = call else { continue }
                if last[row] == width, !excused.contains(row) { repeats.append("row \(row) at \(width)") }
                last[row] = width
                excused.remove(row)
            }
            host.resetCalls()
        }
        audit()

        list.scrollToRow(900, at: .top)
        await stage.settle()
        audit()
        await stage.moveDivider(to: 320, animated: true)
        audit()
        _ = await stage.drain(until: { false }, timeout: 0.5)
        audit()
        list.scrollToRow(100, at: .centeredVertically)
        await stage.settle()
        audit()

        list.noteHeightOfRows(withIndexesChanged: [100, 101])
        excused.formUnion([100, 101])
        audit()
        host.count += 1
        list.insertRows(at: [102])
        last = last.reduce(into: [:]) { renumbered, entry in
            renumbered[entry.key >= 102 ? entry.key + 1 : entry.key] = entry.value
        }
        excused.insert(102)
        audit()
        await stage.moveDivider(to: 150, animated: false)
        _ = await stage.drain(until: { false }, timeout: 0.5)
        audit()
        XCTAssertEqual(repeats, [], "measured again at the width it already had")
        XCTAssertGreaterThan(last.count, 1400, "the audit saw the rows being measured")
    }

    // MARK: - Helpers

    /// A wrapped-text height: fewer lines as the width grows, and fractional.
    private static func wrapped(_ row: Int, _ width: CGFloat) -> CGFloat {
        20 + CGFloat(row % 7) * 3 + 6000 / width
    }

    private func internalScrollView(of list: ExactListView) throws -> NSScrollView {
        try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    /// The mounted rows not measured at the current `W`: their view's width,
    /// and their height for it, in the model and, unless a motion is carrying
    /// the rows between heights (M2), in the view.
    private func unfresh(_ list: ExactListView, _ host: RecordingHost) throws -> [Int] {
        let scroll = try internalScrollView(of: list)
        let width = scroll.contentView.bounds.width
        let moving = scroll.documentView?.subviews.contains { $0 is MotionClock } ?? false
        var wrong: [Int] = []
        list.enumerateAvailableRowViews { view, row in
            let frame = list.convert(view.bounds, from: view)
            let expected = Self.wrapped(row, width)
            if abs(frame.width - width) > 1e-9 || (!moving && abs(frame.height - expected) > 1e-6)
                || abs(list.rect(ofRow: row).height - expected) > 1e-6
            {
                wrong.append(row)
            }
        }
        return wrong.sorted()
    }
}

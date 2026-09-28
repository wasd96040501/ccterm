import AppKit
import XCTest

@testable import TranscriptKit

/// `transcriptView(_:didChangeTailFollowing:)`: whether the viewport is at the
/// end of the scroll, reported on changes only, starting from `true`.
@MainActor
final class TailFollowingTests: XCTestCase {

    private static let windowSize = NSSize(width: 1100, height: 720)

    /// 100 rows of 54 (40 plus the gap): a 5400-point document in a 720-point
    /// window, which a cold mount shows from the top.
    ///
    /// Mounted, laid out, then loaded — the order a host follows (TranscriptKit
    /// §5). Loading before the layout reports whatever a zero-height viewport
    /// makes of the rows, which no host that follows it sees.
    private func mount(rowCount: Int = 100) -> (MountedTranscript, RecordingHost) {
        let mounted = MountedTranscript(size: Self.windowSize)
        let host = RecordingHost(rowCount: rowCount)
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()
        return (mounted, host)
    }

    private func offset(_ mounted: MountedTranscript) -> CGFloat {
        mounted.scrollView.documentVisibleRect.minY
    }

    /// A cold mount lands at the top of a long transcript, which is not the end.
    func testALoadThatLandsAwayFromTheEndReportsLeavingIt() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 99).maxY, 5400, "mount never placed rows")

        XCTAssertEqual(host.tailFollowing, [false])
    }

    /// One transcript shorter than its viewport is always at its end.
    func testATranscriptShorterThanTheViewportNeverReports() throws {
        let (mounted, host) = mount(rowCount: 3)
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 2).maxY, 162, "mount never placed rows")

        XCTAssertEqual(host.tailFollowing, [])
    }

    func testScrollingToTheEndAndAwayReportsEachChange() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        host.resetRecordings()

        mounted.scroll(toY: 5400 - 720)
        mounted.scroll(toY: 5400 - 720 - 0.5)
        mounted.scroll(toY: 2000)
        mounted.scroll(toY: 1000)

        XCTAssertEqual(host.tailFollowing, [true, false], "not reported once per change")
    }

    /// A row the tail follows never left it, so there is nothing to report —
    /// not a departure and a return inside one call.
    func testAnAppendTheTailFollowsReportsNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 5400 - 720)
        host.resetRecordings()

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))
        mounted.settle()

        XCTAssertEqual(offset(mounted), 5454 - 720, "the tail was not followed")
        XCTAssertEqual(host.tailFollowing, [])
    }

    /// The same for the bar growing at the tail.
    func testAnInsetChangeAtTheTailReportsNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 5400 - 720)
        host.resetRecordings()

        mounted.transcript.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 140, right: 0)
        mounted.settle()

        XCTAssertEqual(offset(mounted), 5400 + 140 - 720, "the tail was not kept")
        XCTAssertEqual(host.tailFollowing, [])
    }

    /// A "jump to latest" press: scrolling the last row to the bottom lands on
    /// the tail and says so.
    func testScrollingTheLastRowToTheBottomReportsArriving() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        host.resetRecordings()

        mounted.transcript.scrollToRow(at: 99, scrollPosition: .bottom)

        XCTAssertEqual(offset(mounted), 5400 - 720)
        XCTAssertEqual(host.tailFollowing, [true])
    }
}

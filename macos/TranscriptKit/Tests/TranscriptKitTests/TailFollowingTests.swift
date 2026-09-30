import AppKit
import XCTest

@testable import TranscriptKit

/// `transcriptView(_:didChangeTailFollowing:)`: whether the viewport is at the
/// end of the scroll, reported on changes only.
@MainActor
final class TailFollowingTests: XCTestCase {

    private static let windowSize = NSSize(width: 1100, height: 720)

    /// 100 rows of 40 with a 14-point gap between each two: a 5386-point
    /// document in a 720-point window, whose tail is at 4666.
    ///
    /// Mounted, laid out, then loaded — the order a host follows (TranscriptKit
    /// §5).
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

    private static let tail: CGFloat = 5386 - 720

    private func offset(_ mounted: MountedTranscript) -> CGFloat {
        mounted.scrollView.documentVisibleRect.minY
    }

    /// A transcript loads at its tail, following it, so there is nothing to
    /// report.
    func testALoadLandsAtTheTailAndReportsNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.documentRect(ofRow: 99).maxY, 5386, "mount never placed rows")

        XCTAssertEqual(offset(mounted), Self.tail)
        XCTAssertEqual(host.tailFollowing, [])
    }

    /// One transcript shorter than its viewport is always at its end.
    func testATranscriptShorterThanTheViewportNeverReports() throws {
        let (mounted, host) = mount(rowCount: 3)
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.documentRect(ofRow: 2).maxY, 3 * 40 + 2 * 14, "mount never placed rows")

        XCTAssertEqual(host.tailFollowing, [])
    }

    func testScrollingAwayAndBackReportsEachChange() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        host.resetRecordings()

        mounted.scroll(toY: 2000)
        mounted.scroll(toY: 1000)
        mounted.scroll(toY: Self.tail)

        XCTAssertEqual(host.tailFollowing, [false, true], "not reported once per change")
    }

    /// A row the tail follows never left it, so there is nothing to report —
    /// not a departure and a return inside one call.
    func testAnAppendTheTailFollowsReportsNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        host.resetRecordings()

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))
        mounted.settle()

        XCTAssertEqual(offset(mounted), Self.tail + 54, "the tail was not followed")
        XCTAssertEqual(host.tailFollowing, [])
    }

    /// The same for the bar growing at the tail.
    func testAnInsetChangeAtTheTailReportsNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        host.resetRecordings()

        mounted.transcript.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 140, right: 0)
        mounted.settle()

        XCTAssertEqual(offset(mounted), Self.tail + 140, "the tail was not kept")
        XCTAssertEqual(host.tailFollowing, [])
    }

    /// A "jump to latest" press: scrolling the last row to the bottom lands on
    /// the tail and says so.
    func testScrollingTheLastRowToTheBottomReportsArriving() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 1000)
        host.resetRecordings()

        mounted.transcript.scrollToRow(at: 99, scrollPosition: .bottom)

        XCTAssertEqual(offset(mounted), Self.tail)
        XCTAssertEqual(host.tailFollowing, [true])
    }
}

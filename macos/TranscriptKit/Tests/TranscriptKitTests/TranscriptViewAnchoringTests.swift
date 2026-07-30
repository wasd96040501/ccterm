import AppKit
import TranscriptKit
import XCTest

/// Scroll anchoring: geometry changing above the viewport must not move what the
/// reader is looking at, and a viewport already at the end must follow it.
///
/// Every test asserts the offset *without* settling afterwards — the mutation is
/// supposed to have laid out and restored before it returned, so a test that
/// needed a settle would be reporting a frame drawn at the old offset.
///
/// Uniform 40pt rows in a 720pt viewport, so "held still" is an exact number: 100
/// rows are 4000 tall, and row 50's top edge is at 2000.
@MainActor
final class TranscriptViewAnchoringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let windowSize = NSSize(width: 1100, height: 720)
    private static let rowHeight: CGFloat = 40
    private static let rowCount = 100

    private func mount(insets: NSEdgeInsets = NSEdgeInsets()) -> (MountedTranscript, RecordingHost) {
        let mounted = MountedTranscript(size: Self.windowSize)
        let host = RecordingHost(rowCount: Self.rowCount, rowHeight: Self.rowHeight)
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.contentInsets = insets
        mounted.transcript.reloadData()
        mounted.settle()
        return (mounted, host)
    }

    private func offset(_ mounted: MountedTranscript) -> CGFloat {
        mounted.scrollView.documentVisibleRect.minY
    }

    /// Scrolls until row 50 sits at the top of the viewport, and checks it got
    /// there — which is also the assertion that the mount provoked row geometry at
    /// all.
    private func scrollRow50ToTop(_ mounted: MountedTranscript) {
        mounted.scroll(toY: 2000)
        mounted.settle()
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2000, "mount never placed rows")
        XCTAssertEqual(offset(mounted), 2000)
    }

    // MARK: - Above the viewport

    func testInsertingAboveTheViewportHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.insertRows(5, at: 0)
        mounted.transcript.insertRows(at: IndexSet(0..<5))

        // The same content is at the top of the viewport; it is row 55 now.
        XCTAssertEqual(mounted.transcript.rect(ofRow: 55).minY, 2200)
        XCTAssertEqual(offset(mounted), 2200, "content shifted under the reader")
    }

    func testRemovingAboveTheViewportHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.removeRows(at: IndexSet(0..<5))
        mounted.transcript.removeRows(at: IndexSet(0..<5))

        XCTAssertEqual(mounted.transcript.rect(ofRow: 45).minY, 1800)
        XCTAssertEqual(offset(mounted), 1800, "content shifted under the reader")
    }

    func testARowAboveTheViewportGrowingHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.setHeight(140, forRow: 0)
        mounted.transcript.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))

        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2100)
        XCTAssertEqual(offset(mounted), 2100, "content shifted under the reader")
    }

    func testARowAboveTheViewportShrinkingHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.setHeight(10, forRow: 0)
        mounted.transcript.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))

        XCTAssertEqual(offset(mounted), 1970, "content shifted under the reader")
    }

    /// `reloadRows` re-resolves height as well as content, so it moves geometry
    /// the same way and is anchored the same way.
    func testReloadingARowAboveTheViewportHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.setHeight(140, forRow: 0)
        mounted.transcript.reloadRows(at: IndexSet(integer: 0))

        XCTAssertEqual(offset(mounted), 2100, "content shifted under the reader")
    }

    // MARK: - Below the viewport

    func testInsertingBelowTheViewportMovesNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.insertRows(5, at: 90)
        mounted.transcript.insertRows(at: IndexSet(90..<95))

        XCTAssertEqual(offset(mounted), 2000)
    }

    // MARK: - The tail

    func testAppendingWhileAtTheTailFollowsIt() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 4000 - 720)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 3280, "mount never placed rows")

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))

        // 4040 tall now, so the end of the scroll moved down by exactly the row.
        XCTAssertEqual(offset(mounted), 3320, "the tail was not followed")
    }

    func testAppendingWhileInTheMiddleMovesNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))

        XCTAssertEqual(offset(mounted), 2000)
    }

    /// The same call, twice, behaving differently on nothing but where the offset
    /// is — which is what "no flag being set" means. A persistent
    /// following-the-tail flag would make the second append behave like the first.
    func testScrollingToTheEndReEngagesTailFollowing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2000, "mount never placed rows")
        XCTAssertEqual(offset(mounted), 0, "a cold mount of 100 rows starts at the top")

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))
        XCTAssertEqual(offset(mounted), 0, "not at the end, so nothing should have followed")

        mounted.scroll(toY: 4040 - 720)
        host.insertRows(1, at: 101)
        mounted.transcript.insertRows(at: IndexSet(integer: 101))

        XCTAssertEqual(offset(mounted), 4080 - 720, "the tail was not followed")
    }

    /// A transcript shorter than its viewport is at both ends of the scroll at
    /// once, and the end is the one that matters: appending has to stay visible.
    func testAppendingToATranscriptShorterThanTheViewportFollowsTheTail() throws {
        let mounted = MountedTranscript(size: Self.windowSize)
        defer { mounted.teardown() }
        let host = RecordingHost(rowCount: 3, rowHeight: Self.rowHeight)
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.reloadData()
        mounted.settle()
        XCTAssertEqual(mounted.transcript.rect(ofRow: 2).minY, 80, "mount never placed rows")

        host.insertRows(1, at: 3)
        mounted.transcript.insertRows(at: IndexSet(integer: 3))

        // Still shorter than the viewport, so the end of the scroll is still 0 —
        // following it means not moving, and not moving is correct.
        XCTAssertEqual(offset(mounted), 0)
        XCTAssertEqual(mounted.transcript.numberOfRows, 4)
    }

    // MARK: - Batching

    /// Mixed mutations in one group: the anchor is renumbered by each of them and
    /// restored once, so the arithmetic has to compose. Five rows added above and
    /// three removed above is a net two, and row 50 becomes row 52.
    func testABatchHoldsTheViewportStillAcrossMixedMutations() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        mounted.transcript.beginUpdates()
        host.insertRows(5, at: 0)
        mounted.transcript.insertRows(at: IndexSet(0..<5))
        host.removeRows(at: IndexSet(10..<13))
        mounted.transcript.removeRows(at: IndexSet(10..<13))
        mounted.transcript.endUpdates()

        XCTAssertEqual(mounted.transcript.numberOfRows, 102)
        XCTAssertEqual(mounted.transcript.rect(ofRow: 52).minY, 2080)
        XCTAssertEqual(offset(mounted), 2080, "content shifted under the reader")
    }

    // MARK: - The anchor row itself

    /// Nothing to hold still: what was at the top of the viewport is gone. The
    /// next surviving row takes its place there, which drops the part of the old
    /// row that was scrolled past.
    func testRemovingTheAnchorRowSnapsToTheNextSurvivor() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 2010)
        mounted.settle()
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2000, "mount never placed rows")
        XCTAssertEqual(offset(mounted), 2010, "row 50 should be 10pt scrolled past")

        host.removeRows(at: IndexSet(50..<53))
        mounted.transcript.removeRows(at: IndexSet(50..<53))

        XCTAssertEqual(offset(mounted), 2000, "the survivor's top edge belongs at the viewport top")
    }

    /// Restoring an offset needs the geometry the mutation produced, which means
    /// the host is asked for it from inside its own mutation call. Worth pinning:
    /// it is the one way anchoring is visible to a host, and it is why the model
    /// has to be consistent before the call rather than by the end of the tick.
    func testAMutationAsksTheHostBeforeItReturns() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.insertRows(5, at: 0)
        host.resetRecordings()
        mounted.transcript.insertRows(at: IndexSet(0..<5))

        XCTAssertFalse(
            host.heightWidths.isEmpty,
            "the inserted rows were not measured until after the call returned")
    }

    /// Holding the content still means suppressing the implicit animation the row
    /// geometry would otherwise get, and `CATransaction.setDisableActions` is
    /// process-wide state until the grouping that set it ends. A leak would turn off
    /// animation for everything else in the tick — every other view in the window
    /// included — with nothing pointing back here.
    func testAMutationLeavesNoAnimationSuppressionBehind() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)
        XCTAssertFalse(CATransaction.disableActions(), "something suppressed before we started")

        host.insertRows(5, at: 0)
        mounted.transcript.insertRows(at: IndexSet(0..<5))
        XCTAssertFalse(CATransaction.disableActions(), "a mutation left actions disabled")

        mounted.transcript.beginUpdates()
        host.insertRows(1, at: 0)
        mounted.transcript.insertRows(at: IndexSet(integer: 0))
        mounted.transcript.endUpdates()
        XCTAssertFalse(CATransaction.disableActions(), "a batch left actions disabled")
    }

    // MARK: - Content insets

    /// The anchor is measured from the edge of what the chrome leaves visible, so
    /// a top inset must cancel out of both the sample and the restore.
    func testAnchoringMeasuresFromBelowTheTopInset() throws {
        let (mounted, host) = mount(insets: NSEdgeInsets(top: 12, left: 0, bottom: 60, right: 0))
        defer { mounted.teardown() }
        mounted.transcript.scrollToRow(at: 50, scrollPosition: .top)
        XCTAssertEqual(offset(mounted), 2000 - 12, "mount never placed rows")

        host.insertRows(5, at: 0)
        mounted.transcript.insertRows(at: IndexSet(0..<5))

        XCTAssertEqual(mounted.transcript.rect(ofRow: 55).minY, 2200)
        XCTAssertEqual(offset(mounted), 2200 - 12, "content shifted under the reader")
    }
}

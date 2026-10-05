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
/// Uniform 40pt rows, 14 apart, in a 720pt viewport, so "held still" is an exact
/// number: a row and the gap after it cost 54, 100 rows are 5386 tall (no gap
/// after the last), and row 50's top edge is at
/// 2700.
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
        mounted.scroll(toY: 2700)
        mounted.settle()
        XCTAssertEqual(mounted.documentRect(ofRow: 50).minY, 2700, "mount never placed rows")
        XCTAssertEqual(offset(mounted), 2700)
    }

    // MARK: - Above the viewport

    func testInsertingAboveTheViewportHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.insertRows(5, at: 0)
        mounted.transcript.insertRows(at: IndexSet(0..<5))

        // The same content is at the top of the viewport; it is row 55 now.
        XCTAssertEqual(mounted.documentRect(ofRow: 55).minY, 2970)
        XCTAssertEqual(offset(mounted), 2970, "content shifted under the reader")
    }

    func testRemovingAboveTheViewportHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.removeRows(at: IndexSet(0..<5))
        mounted.transcript.removeRows(at: IndexSet(0..<5))

        XCTAssertEqual(mounted.documentRect(ofRow: 45).minY, 2430)
        XCTAssertEqual(offset(mounted), 2430, "content shifted under the reader")
    }

    func testARowAboveTheViewportGrowingHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.setHeight(140, forRow: 0)
        mounted.transcript.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))

        XCTAssertEqual(mounted.documentRect(ofRow: 50).minY, 2800)
        XCTAssertEqual(offset(mounted), 2800, "content shifted under the reader")
    }

    func testARowAboveTheViewportShrinkingHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.setHeight(10, forRow: 0)
        mounted.transcript.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))

        XCTAssertEqual(offset(mounted), 2670, "content shifted under the reader")
    }

    /// `reloadRows` re-resolves height as well as content, so it moves geometry
    /// the same way and is anchored the same way.
    func testReloadingARowAboveTheViewportHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.setHeight(140, forRow: 0)
        mounted.transcript.reloadRows(at: IndexSet(integer: 0))

        XCTAssertEqual(offset(mounted), 2800, "content shifted under the reader")
    }

    // MARK: - Below the viewport

    func testInsertingBelowTheViewportMovesNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.insertRows(5, at: 90)
        mounted.transcript.insertRows(at: IndexSet(90..<95))

        XCTAssertEqual(offset(mounted), 2700)
    }

    // MARK: - Moving

    /// A move with no motion, so the end state is exact: a group of duration 0
    /// is how AppKit says so.
    private func move(_ mounted: MountedTranscript, _ host: RecordingHost, from: Int, to: Int) {
        host.moveRow(at: from, to: to)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            mounted.transcript.moveRow(at: from, to: to)
        }
        mounted.settle()
    }

    func testMovingARowAmongRowsAboveTheViewportMovesNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        move(mounted, host, from: 10, to: 20)

        XCTAssertEqual(mounted.documentRect(ofRow: 50).minY, 2700)
        XCTAssertEqual(offset(mounted), 2700)
    }

    func testMovingARowFromAboveTheViewportToBelowHoldsTheContentStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        move(mounted, host, from: 3, to: 90)

        // What was row 50 is row 49 now, still at the top of the viewport.
        XCTAssertEqual(mounted.documentRect(ofRow: 49).minY, 2646)
        XCTAssertEqual(offset(mounted), 2646, "content shifted under the reader")
    }

    func testAMovedRowKeepsItsView() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        let moved = try XCTUnwrap(
            mounted.transcript.descendants(ofType: RecordingHost.ProbeView.self)
                .first { mounted.transcript.row(for: $0) == 52 })
        moved.setAccessibilityIdentifier("moved")

        move(mounted, host, from: 52, to: 54)

        XCTAssertEqual(mounted.transcript.row(for: moved), 54, "the row's view went elsewhere")
        XCTAssertEqual(moved.accessibilityIdentifier(), "moved")
    }

    func testMovingRowsInABatchFollowsTheBatchsOwnNumbering() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)
        let ids = host.rows.map(\.id)

        host.moveRow(at: 60, to: 55)
        host.moveRow(at: 56, to: 58)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            mounted.transcript.performBatchUpdates {
                mounted.transcript.moveRow(at: 60, to: 55)
                mounted.transcript.moveRow(at: 56, to: 58)
            }
        }
        mounted.settle()

        XCTAssertEqual(host.rows.count, mounted.transcript.numberOfRows)
        XCTAssertEqual(host.rows[55].id, ids[60])
        XCTAssertEqual(offset(mounted), 2700)
    }

    // MARK: - The tail

    func testAppendingWhileAtTheTailFollowsIt() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 5386 - 720)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 4666, "mount never placed rows")

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))

        // 5440 tall now, so the end of the scroll moved down by exactly the row
        // and the gap that came with it.
        XCTAssertEqual(offset(mounted), 4720, "the tail was not followed")
    }

    func testAppendingWhileInTheMiddleMovesNothing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))

        XCTAssertEqual(offset(mounted), 2700)
    }

    /// The same call, twice, behaving differently on nothing but where the offset
    /// is — which is what "no flag being set" means. A persistent
    /// following-the-tail flag would make the second append behave like the first.
    func testScrollingToTheEndReEngagesTailFollowing() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.documentRect(ofRow: 50).minY, 2700, "mount never placed rows")
        mounted.scroll(toY: 0)
        XCTAssertEqual(offset(mounted), 0, "premise: away from the tail")

        host.insertRows(1, at: 100)
        mounted.transcript.insertRows(at: IndexSet(integer: 100))
        XCTAssertEqual(offset(mounted), 0, "not at the end, so nothing should have followed")

        mounted.scroll(toY: 5440 - 720)
        host.insertRows(1, at: 101)
        mounted.transcript.insertRows(at: IndexSet(integer: 101))

        XCTAssertEqual(offset(mounted), 5494 - 720, "the tail was not followed")
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
        XCTAssertEqual(mounted.documentRect(ofRow: 2).minY, 108, "mount never placed rows")

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

        mounted.transcript.performBatchUpdates {
            host.insertRows(5, at: 0)
            mounted.transcript.insertRows(at: IndexSet(0..<5))
            host.removeRows(at: IndexSet(10..<13))
            mounted.transcript.removeRows(at: IndexSet(10..<13))
        }

        XCTAssertEqual(mounted.transcript.numberOfRows, 102)
        XCTAssertEqual(mounted.documentRect(ofRow: 52).minY, 2808)
        XCTAssertEqual(offset(mounted), 2808, "content shifted under the reader")
    }

    /// A host opening every list at once: rows inserted after every sixth row,
    /// each of those rows reloaded, above, at and below the viewport, in one
    /// group. Near the end, the top row's new place is past the end of the
    /// content as it was — it still lands there, not where the old content
    /// stopped.
    func testABatchGrowingTheContentPastItsOldEndHoldsTheTopRowStill() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 85 * 54)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 85 * 54, "premise: row 85 is at the top")

        var anchor = 85
        mounted.transcript.performBatchUpdates {
            var row = 0
            while row < host.numberOfRows(in: mounted.transcript) {
                host.insertRows(4, at: row + 1, height: 24)
                mounted.transcript.insertRows(at: IndexSet(row + 1..<row + 5))
                mounted.transcript.reloadRows(at: IndexSet(integer: row))
                if row < anchor { anchor += 4 }
                row += 6
            }
        }

        XCTAssertGreaterThan(
            mounted.documentRect(ofRow: anchor).minY, 100 * 54 - 720,
            "premise: the row's new place is past the old end")
        XCTAssertEqual(offset(mounted), mounted.documentRect(ofRow: anchor).minY, "content shifted under the reader")
    }

    // MARK: - The anchor row itself

    /// Nothing to hold still: what was at the top of the viewport is gone. The
    /// next surviving row holds its own place on screen (ExactList A5).
    func testRemovingTheAnchorRowSnapsToTheNextSurvivor() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 2710)
        mounted.settle()
        XCTAssertEqual(mounted.documentRect(ofRow: 50).minY, 2700, "mount never placed rows")
        XCTAssertEqual(offset(mounted), 2710, "row 50 should be 10pt scrolled past")

        host.removeRows(at: IndexSet(50..<53))
        mounted.transcript.removeRows(at: IndexSet(50..<53))

        // Row 53 was at 2862, 152 below the viewport's top; it is row 50 now,
        // at 2700.
        XCTAssertEqual(offset(mounted), 2700 - (2862 - 2710), "the survivor moved on screen")
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

        mounted.transcript.performBatchUpdates {
            host.insertRows(1, at: 0)
            mounted.transcript.insertRows(at: IndexSet(integer: 0))
        }
        XCTAssertFalse(CATransaction.disableActions(), "a batch left actions disabled")
    }

    // MARK: - Content insets

    /// The anchor is measured from the edge of what the chrome leaves visible, so
    /// a top inset must cancel out of both the sample and the restore.
    func testAnchoringMeasuresFromBelowTheTopInset() throws {
        let (mounted, host) = mount(insets: NSEdgeInsets(top: 12, left: 0, bottom: 60, right: 0))
        defer { mounted.teardown() }
        mounted.transcript.scrollToRow(at: 50, scrollPosition: .top)
        XCTAssertEqual(offset(mounted), 2700 - 12, "mount never placed rows")

        host.insertRows(5, at: 0)
        mounted.transcript.insertRows(at: IndexSet(0..<5))

        XCTAssertEqual(mounted.documentRect(ofRow: 55).minY, 2970)
        XCTAssertEqual(offset(mounted), 2970 - 12, "content shifted under the reader")
    }

    /// An input bar growing a line at the tail: the inset grows, the transcript
    /// stays the size it was, and the scroll follows the tail so the last row
    /// comes to rest above the taller bar.
    func testGrowingTheBottomInsetAtTheTailKeepsTheTail() throws {
        let (mounted, _) = mount(insets: NSEdgeInsets(top: 0, left: 0, bottom: 60, right: 0))
        defer { mounted.teardown() }
        mounted.scroll(toY: 5386 + 60 - 720)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 4726, "mount never placed rows")
        let frame = mounted.transcript.frame

        mounted.transcript.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 140, right: 0)

        XCTAssertEqual(offset(mounted), 5386 + 140 - 720, "the last row went under the bar")
        XCTAssertEqual(mounted.transcript.frame, frame, "the transcript moved instead of its scroll")
    }

    /// The bar shrinking back — a sent message clearing a multi-line draft.
    func testShrinkingTheBottomInsetAtTheTailKeepsTheTail() throws {
        let (mounted, _) = mount(insets: NSEdgeInsets(top: 0, left: 0, bottom: 140, right: 0))
        defer { mounted.teardown() }
        mounted.scroll(toY: 5386 + 140 - 720)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 4806, "mount never placed rows")

        mounted.transcript.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)

        XCTAssertEqual(offset(mounted), 5386 + 60 - 720)
    }

    /// A reader in the history: the bar growing under them moves nothing.
    func testGrowingTheBottomInsetInTheMiddleMovesNothing() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        mounted.transcript.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 140, right: 0)

        XCTAssertEqual(offset(mounted), 2700)
    }

    /// Chrome arriving at the top holds the row the reader was on below it rather
    /// than sliding it underneath.
    func testGrowingTheTopInsetKeepsTheTopRowBelowIt() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        scrollRow50ToTop(mounted)

        mounted.transcript.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)

        XCTAssertEqual(offset(mounted), 2700 - 52, "row 50 slid under the chrome")
    }
}

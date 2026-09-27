import AppKit
import TranscriptKit
import XCTest

/// `scrollToRow(at:scrollPosition:)` — where each position lands, and what
/// happens at the ends of the range.
///
/// Uniform 40pt rows, 14 apart, in a 720pt viewport — so a row costs 54 and row
/// *n*'s rect starts at `n * 54`. Every expected offset is written as the
/// arithmetic that produced it. Each test opens by asserting the mount provoked
/// row geometry: `rect(ofRow:)` answers `NSZeroRect` for a row the table never
/// placed, and every landing assertion would then pass against zeroes.
///
/// A row rect is the row plus its gap, which is what the landing positions are
/// measured against: `.bottom` puts that rect's bottom edge at the viewport's,
/// leaving the half of the gap below the row showing.
@MainActor
final class TranscriptViewScrollTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let windowSize = NSSize(width: 1100, height: 720)
    private static let rowHeight: CGFloat = 40
    private static let rowCount = 100
    /// 100 rows of 54 in a 720 viewport: 5400 tall, so the last legal offset is
    /// 4680.
    private static let maxOffset: CGFloat = 5400 - 720

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

    // MARK: - Landing positions

    func testTopLandsTheRowsTopEdgeAtTheViewportTop() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2700, "mount never placed rows")

        mounted.transcript.scrollToRow(at: 50, scrollPosition: .top)

        XCTAssertEqual(offset(mounted), 2700)
    }

    func testCenterCentresTheRowInTheViewport() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2700, "mount never placed rows")

        mounted.transcript.scrollToRow(at: 50, scrollPosition: .center)

        // Row rect 2700...2754, so its centre is 2727, half a 720 viewport
        // below it.
        XCTAssertEqual(offset(mounted), 2727 - 360)
    }

    func testBottomLandsTheRowsBottomEdgeAtTheViewportBottom() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2700, "mount never placed rows")

        mounted.transcript.scrollToRow(at: 50, scrollPosition: .bottom)

        // The rect's bottom edge, gap included, at the viewport's.
        XCTAssertEqual(offset(mounted), 2754 - 720)
    }

    // MARK: - Nearest edge

    func testNearestEdgeLeavesAnAlreadyVisibleRowAlone() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 5).minY, 270, "mount never placed rows")
        XCTAssertEqual(offset(mounted), 0)

        mounted.transcript.scrollToRow(at: 5, scrollPosition: .nearestEdge)

        XCTAssertEqual(offset(mounted), 0, "a fully visible row should not have moved anything")
    }

    func testNearestEdgeScrollsARowBelowUpToTheBottomEdge() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 20).maxY, 1134, "mount never placed rows")

        mounted.transcript.scrollToRow(at: 20, scrollPosition: .nearestEdge)

        // The least that brings 1080...1134 into a 720 viewport.
        XCTAssertEqual(offset(mounted), 1134 - 720)
    }

    func testNearestEdgeScrollsARowAboveDownToTheTopEdge() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 2700)
        XCTAssertEqual(offset(mounted), 2700)

        mounted.transcript.scrollToRow(at: 3, scrollPosition: .nearestEdge)

        XCTAssertEqual(offset(mounted), 162)
    }

    /// A row taller than the viewport can't be brought fully in, so its start is
    /// shown rather than the search for a "least amount" running off.
    func testNearestEdgeShowsTheStartOfARowTallerThanTheViewport() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        host.setHeight(1200, forRow: 10)
        mounted.transcript.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 10))
        XCTAssertEqual(mounted.transcript.rect(ofRow: 10).height, 1200 + 14)

        mounted.transcript.scrollToRow(at: 10, scrollPosition: .nearestEdge)

        XCTAssertEqual(offset(mounted), 540)
    }

    // MARK: - Ends of the range

    func testAPositionBeyondTheStartClampsToIt() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 0).minY, 0, "mount never placed rows")
        mounted.scroll(toY: 2700)

        // Centring row 0 would need an offset of -333.
        mounted.transcript.scrollToRow(at: 0, scrollPosition: .center)

        XCTAssertEqual(offset(mounted), 0)
    }

    func testAPositionBeyondTheEndClampsToIt() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 99).minY, 5346, "mount never placed rows")

        // Putting row 99's top at the viewport top would need 5346.
        mounted.transcript.scrollToRow(at: 99, scrollPosition: .top)

        XCTAssertEqual(offset(mounted), Self.maxOffset)
    }

    func testAnOutOfRangeRowScrollsNothing() throws {
        let (mounted, _) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2700, "mount never placed rows")
        mounted.scroll(toY: 1000)

        mounted.transcript.scrollToRow(at: 100, scrollPosition: .top)
        mounted.transcript.scrollToRow(at: -1, scrollPosition: .top)

        XCTAssertEqual(offset(mounted), 1000)
    }

    /// A reload leaves the table with nothing placed until it next lays out, so a
    /// scroll in the same tick has to provoke that pass rather than read zeroes
    /// from it — which is what makes the pair atomic, with no frame in between at
    /// the old offset.
    func testScrollingRightAfterAReloadLandsInTheSamePass() throws {
        let (mounted, host) = mount()
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2700, "mount never placed rows")

        host.insertRows(20, at: 0)
        mounted.transcript.reloadData()
        mounted.transcript.scrollToRow(at: 70, scrollPosition: .top)

        XCTAssertEqual(offset(mounted), 3780)
    }

    // MARK: - Content insets

    /// Insets describe chrome the transcript scrolls *under*, so a landing
    /// position is measured against what the chrome leaves visible — not against
    /// the clip's own edges.
    func testPositionsAreMeasuredBelowTheTopInsetAndAboveTheBottomOne() throws {
        let (mounted, _) = mount(insets: NSEdgeInsets(top: 12, left: 0, bottom: 60, right: 0))
        defer { mounted.teardown() }
        XCTAssertEqual(mounted.transcript.rect(ofRow: 50).minY, 2700, "mount never placed rows")

        mounted.transcript.scrollToRow(at: 50, scrollPosition: .top)
        XCTAssertEqual(offset(mounted), 2700 - 12, "row 50's top should sit below the 12pt inset")

        mounted.transcript.scrollToRow(at: 50, scrollPosition: .bottom)
        // 720 of clip less both insets leaves 648 visible; the row's bottom edge
        // goes at the bottom of that.
        XCTAssertEqual(offset(mounted), 2754 - 648 - 12)
    }
}

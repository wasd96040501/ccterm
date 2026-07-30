import AppKit
import TranscriptKit
import XCTest

/// Row geometry, content width, and who gets asked what.
///
/// Every test opens by asserting the harness actually provoked the transcript —
/// a mount that silently never lays out makes every later assertion pass for the
/// wrong reason, and that is the failure mode a geometry test is most likely to
/// hide.
@MainActor
final class TranscriptViewGeometryTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Window width and clamp are the numbers the demo was checked by eye at, so
    /// a disagreement here means the off-screen mount and a real window differ —
    /// not that the transcript is wrong.
    private static let windowSize = NSSize(width: 1100, height: 720)
    private static let maxContentWidth: CGFloat = 720

    private func mount(rows: Int, rowHeight: CGFloat = 40) -> (MountedTranscript, RecordingHost) {
        let mounted = MountedTranscript(size: Self.windowSize)
        let host = RecordingHost(rowCount: rows, rowHeight: rowHeight)
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.maxContentWidth = Self.maxContentWidth
        mounted.transcript.reloadData()
        mounted.settle()
        return (mounted, host)
    }

    func testMountProvokesRowGeometry() throws {
        let (mounted, host) = mount(rows: 24)
        defer { mounted.teardown() }

        XCTAssertFalse(host.heightWidths.isEmpty, "the transcript never asked for a row height")
        XCTAssertGreaterThan(host.viewCalls, 0, "the transcript never asked for a row view")
        XCTAssertEqual(mounted.transcript.numberOfRows, 24)

        // Fixed row height, so row n starts at n * height.
        XCTAssertEqual(mounted.transcript.rect(ofRow: 0).origin.y, 0)
        XCTAssertEqual(mounted.transcript.rect(ofRow: 3).origin.y, 120)
        XCTAssertEqual(mounted.transcript.rect(ofRow: 3).height, 40)
    }

    /// The eyeball anchor: 1100 wide, clamped at 720, content 720 and centred.
    func testContentWidthClampsAndHostedViewsCentre() throws {
        let (mounted, host) = mount(rows: 24)
        defer { mounted.teardown() }

        XCTAssertEqual(mounted.transcript.contentWidth, 720)
        XCTAssertEqual(Set(host.heightWidths), [720], "rows measured at a width other than 720")

        let probes = mounted.transcript.descendants(ofType: RecordingHost.ProbeView.self)
        XCTAssertFalse(probes.isEmpty, "no hosted view reached the view tree")
        for probe in probes {
            let cell = try XCTUnwrap(probe.superview)
            XCTAssertEqual(probe.frame.width, 720, accuracy: 0.5)
            XCTAssertEqual(probe.frame.midX, cell.bounds.midX, accuracy: 0.5)
        }
    }

    /// Only a screenful of views exists no matter how long the transcript is —
    /// the reason a row-based view beats a stack of everything.
    func testViewsRecycleRatherThanAccumulate() throws {
        let (mounted, host) = mount(rows: 500)
        defer { mounted.teardown() }

        let onScreen = Int((Self.windowSize.height / 40).rounded(.up)) + 2
        XCTAssertLessThanOrEqual(host.builds, onScreen)
        XCTAssertLessThanOrEqual(
            mounted.transcript.descendants(ofType: RecordingHost.ProbeView.self).count, onScreen)
    }

    // MARK: - Content width invalidation

    /// Narrowing past the clamp changes the width the delegate answered for, so
    /// every height it already gave is stale.
    func testNarrowingBelowTheClampReAsksAtTheNewWidth() throws {
        let (mounted, host) = mount(rows: 24)
        defer { mounted.teardown() }

        host.resetRecordings()
        mounted.setContentWidth(500)
        mounted.settle()

        XCTAssertFalse(host.heightWidths.isEmpty, "heights were not re-asked after narrowing")
        XCTAssertEqual(
            Set(host.heightWidths), [mounted.transcript.contentWidth],
            "re-asked at a width other than the transcript's current one")
        XCTAssertLessThan(mounted.transcript.contentWidth, 720)
    }

    /// Above the clamp the number handed to the delegate stops moving, so
    /// resizing there is free.
    func testWideningAboveTheClampReAsksNothing() throws {
        let (mounted, host) = mount(rows: 24)
        defer { mounted.teardown() }

        host.resetRecordings()
        mounted.setContentWidth(1400)
        mounted.settle()

        XCTAssertEqual(mounted.transcript.contentWidth, 720)
        XCTAssertEqual(host.heightWidths, [], "heights were re-asked despite the clamp holding")
    }

    /// A cold mount should settle on one content width, not measure everything
    /// twice — once at whatever the table's own initial width is, then again
    /// once the scroll view has sized it.
    func testColdMountMeasuresEachRowAtOneWidthOnly() throws {
        let (mounted, host) = mount(rows: 24)
        defer { mounted.teardown() }

        XCTAssertEqual(
            Set(host.heightWidths), [720],
            "cold mount measured at more than one width: "
                + "\(host.heightWidths.reduce(into: [CGFloat: Int]()) { $0[$1, default: 0] += 1 })")
        XCTAssertEqual(host.heightWidths.count, 24, "each row should be measured once")
    }
}

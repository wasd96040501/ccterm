import AppKit
import XCTest

@testable import TranscriptKit

/// `.markdown` rows end to end: the transcript measures them itself, draws them
/// through its own cell, and leaves the delegate out of both.
///
/// Mounted rather than pure, unlike `BlockSelectionTests` — the block tree
/// is a value, but *whether the transcript reaches for one* is only observable
/// once `NSTableView` lays out and starts asking.
@MainActor
final class MarkdownRowTests: XCTestCase {

    private var mounted: MountedTranscript!

    /// Held by the test, because the transcript holds its data source and
    /// delegate weakly — a fixture that only passed the host in would be
    /// measuring a transcript whose data source had already gone.
    private var host: MarkdownHost!

    override func tearDown() {
        mounted?.teardown()
        mounted = nil
        host = nil
        super.tearDown()
    }

    @discardableResult
    private func mount(_ sources: [String], width: CGFloat = 600) -> MarkdownHost {
        let host = MarkdownHost(sources: sources)
        self.host = host
        mounted = MountedTranscript(size: NSSize(width: width, height: 400))
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()
        return host
    }

    // MARK: - Measured by the transcript, not the delegate

    func testMarkdownRowsAreMeasuredWithoutAskingTheDelegate() {
        let host = mount(["# Heading\n\nA paragraph.", "Another paragraph."])

        XCTAssertEqual(mounted.transcript.numberOfRows, 2)
        // The provocation check: a mount that never laid out would leave every
        // row at zero and make the rest of this pass vacuously.
        XCTAssertGreaterThan(mounted.transcript.rect(ofRow: 0).height, 0)
        XCTAssertGreaterThan(mounted.transcript.rect(ofRow: 1).height, 0)

        // `heightOfRow` is the `.view` path. A markdown row must not touch it.
        XCTAssertTrue(host.heightWidths.isEmpty)
        XCTAssertEqual(host.viewCalls, 0)
    }

    /// A heading and a paragraph of the same text differ in height, which is the
    /// cheapest proof that the tree was actually built from the markdown rather
    /// than from the raw string.
    func testHeadingIsTallerThanTheSameTextAsProse() {
        mount(["# Heading", "Heading"])
        XCTAssertGreaterThan(
            mounted.transcript.rect(ofRow: 0).height, mounted.transcript.rect(ofRow: 1).height)
    }

    // MARK: - Drawn by the transcript's own cell

    func testMarkdownRowIsServedThroughTheTranscriptsOwnCell() {
        mount(["A paragraph long enough to occupy a row."])
        XCTAssertEqual(mounted.transcript.descendants(ofType: MarkdownCellView.self).count, 1)
    }

    /// Both kinds of row on screen at once. They share one recycling pool, so a
    /// cell handed back from the wrong kind of row is a real failure mode — and
    /// one an all-markdown fixture cannot see.
    func testMarkdownAndHostRowsCoexist() {
        let host = mount(["Markdown row.", MarkdownHost.hostRowMarker, "Another markdown row."])

        XCTAssertEqual(mounted.transcript.descendants(ofType: MarkdownCellView.self).count, 2)
        XCTAssertEqual(mounted.transcript.descendants(ofType: RecordingHost.ProbeView.self).count, 1)
        // Asked about the host's row, and only that one.
        XCTAssertEqual(host.heightWidths.count, 1)
    }

    // MARK: - Re-measured on a width change

    /// Narrowing wraps the text onto more lines, so the row gets taller — the
    /// self-drawn half of the invalidation `.view` rows get through
    /// `heightOfRow`'s `width` parameter.
    func testNarrowingRemeasuresMarkdownRows() {
        mount([String(repeating: "word ", count: 80)], width: 700)
        let wide = mounted.transcript.rect(ofRow: 0).height

        mounted.setContentWidth(320)
        mounted.settle()

        XCTAssertGreaterThan(mounted.transcript.rect(ofRow: 0).height, wide)
    }
}

/// Answers `.markdown` for every row but the one carrying `hostRowMarker`, which
/// it serves the `.view` way — so one fixture covers both paths.
@MainActor
private final class MarkdownHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    static let hostRowMarker = "\u{0}host-drawn"

    private let sources: [String]

    private(set) var heightWidths: [CGFloat] = []
    private(set) var viewCalls = 0

    init(sources: [String]) {
        self.sources = sources
        super.init()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { sources.count }

    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent {
        sources[row] == Self.hostRowMarker ? .view : .markdown(sources[row])
    }

    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        heightWidths.append(width)
        return 40
    }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        viewCalls += 1
        return transcriptView.makeView(withIdentifier: Self.probe) { RecordingHost.ProbeView() }
    }

    private static let probe = NSUserInterfaceItemIdentifier("MarkdownRowTests.probe")
}

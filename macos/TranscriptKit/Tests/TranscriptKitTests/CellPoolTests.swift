import AppKit
import XCTest

@testable import TranscriptKit

/// Drawn rows and hosted rows recycle through pools of their own: a cell
/// keeps the view it hosted while it waits, so one pool for both would hand
/// a reply's cell to a host row and throw its view away — a host view built,
/// and a block view built, nearly every time a reply and a `.view` row
/// alternate on screen.
@MainActor
final class CellPoolTests: XCTestCase {
    /// Replies between `.view` rows, as a transcript of work reads.
    private final class InterleavedHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {
        let ids = (0..<600).map { _ in UUID() }
        private(set) var builds = 0

        func numberOfRows(in transcriptView: TranscriptView) -> Int { ids.count }

        func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
            TranscriptRow(
                id: ids[row], content: row.isMultiple(of: 2) ? .markdown("Reply \(row), a line of words.") : .view)
        }

        func transcriptView(_ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat) -> CGFloat { 24 }

        func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
            transcriptView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("test.hosted")) {
                builds += 1
                return NSView()
            }
        }
    }

    func testScrollingThroughAlternatingRowsBuildsNoViewsPastTheFirstScreens() {
        let mounted = MountedTranscript(size: NSSize(width: 800, height: 600))
        let host = InterleavedHost()
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.reloadData()
        mounted.settle()
        mounted.scroll(toY: 0)
        mounted.settle()
        let firstScreens = host.builds
        let height = mounted.scrollView.documentView?.frame.height ?? 0
        var y: CGFloat = 0
        while y < height {
            y += 300
            mounted.scroll(toY: y)
            mounted.settle()
        }
        XCTAssertGreaterThan(firstScreens, 0, "premise: host rows were shown")
        XCTAssertLessThanOrEqual(
            host.builds, firstScreens * 2,
            "scrolling the whole transcript built \(host.builds) host views; the first screens needed \(firstScreens)")
    }
}

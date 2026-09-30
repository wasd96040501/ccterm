import AppKit
import XCTest

@testable import TranscriptKit

/// The gap above each row is the host's to give, for rows the transcript draws
/// and rows it hosts alike, and the transcript's own gap between entries is
/// what a row gets when the host gives none.
@MainActor
final class RowSpacingTests: XCTestCase {

    private final class SpacingHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {
        var rows: [(id: UUID, content: TranscriptRowContent, spacing: CGFloat?)] = [
            (UUID(), .markdown("A reply, drawn by the transcript."), nil),
            (UUID(), .view, 0),
            (UUID(), .view, 0),
            (UUID(), .view, 6),
            (UUID(), .markdown("The next entry."), nil),
        ]

        func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

        func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
            TranscriptRow(id: rows[row].id, content: rows[row].content)
        }

        func transcriptView(
            _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
        ) -> CGFloat { 24 }

        func transcriptView(_ transcriptView: TranscriptView, customSpacingAboveRow row: Int) -> CGFloat? {
            rows[row].spacing
        }

        func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
            transcriptView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("spacing.row")) { NSView() }
        }
    }

    func testEachRowSitsTheGapItsHostGivesIt() throws {
        let mounted = MountedTranscript(size: NSSize(width: 600, height: 400))
        defer { mounted.teardown() }
        let host = SpacingHost()
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()

        let transcript = mounted.transcript
        func gap(above row: Int) -> CGFloat { transcript.rect(ofRow: row).minY - transcript.rect(ofRow: row - 1).maxY }
        XCTAssertEqual(gap(above: 1), 0, "a row asking for 0 sits flush under a drawn row")
        XCTAssertEqual(gap(above: 2), 0)
        XCTAssertEqual(gap(above: 3), 6)
        XCTAssertEqual(gap(above: 4), 14, "no answer is the transcript's gap between entries")

        // Inserted rows bring their own gap; the rows around them keep theirs.
        host.rows.insert((UUID(), .view, 0), at: 1)
        transcript.insertRows(at: [1], withAnimation: [])
        mounted.settle()
        XCTAssertEqual(gap(above: 1), 0)
        XCTAssertEqual(gap(above: 2), 0)
        XCTAssertEqual(gap(above: 5), 14)

        // A noted row is asked again.
        host.rows[4].spacing = 2
        transcript.noteHeightOfRows(withIndexesChanged: [4])
        mounted.settle()
        XCTAssertEqual(gap(above: 4), 2)
    }
}

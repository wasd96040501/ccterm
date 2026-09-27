import AppKit
import XCTest

@testable import TranscriptKit

/// How a find looks, captured as the window server composited it, in both
/// appearances: `/tmp/transcriptkit-screenshots/FindPresentation-{light,dark}.png`.
///
/// **For eyes, not a gate.** Skipped by `make test-kit`; run it with
/// `make test-kit FILTER=FindPresentationSnapshotTests` and open the two files.
/// What it is for is what `FindTests` cannot have an opinion on: that the
/// dimming reads as AppKit's, that a match on a dark card is still findable, that
/// the bubble's black characters sit exactly on the row's, and that dark mode
/// outlines rather than dims. The geometry under all of it — every lit rectangle
/// on its characters, the bubble on the current one, both carried by a scroll — is
/// asserted there.
///
/// Rows are chosen for the surfaces a match can land on: prose, a heading, a
/// code card, a table cell, and a user's bubble.
@MainActor
final class FindPresentationSnapshotTests: XCTestCase {

    func testFindPresentation() async throws {
        let host = SnapshotHost(rows: [
            .markdown(
                """
                ## Claude in a heading

                A paragraph that mentions Claude twice, so that Claude is lit \
                more than once on a single line of prose.

                ```swift
                let model = "Claude" // a match on a code card
                ```

                | Name | Note |
                |------|------|
                | Claude | in a table cell |
                """),
            .userMessage("Can Claude find text in my own message too?"),
            .markdown("The last row, with one more Claude near its end."),
        ])
        let mounted = MountedTranscript(size: NSSize(width: 720, height: 560))
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.maxContentWidth = 620
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()

        mounted.transcript.find("claude")
        await mounted.settleFind()
        XCTAssertGreaterThan(
            mounted.transcript.numberOfFindMatches, 5, "premise: the rows have matches to show")
        // The second hit, so the bubble sits mid-paragraph rather than in the
        // heading's larger type.
        mounted.transcript.findNext()
        mounted.settle()

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            mounted.window.appearance = NSAppearance(named: appearance)
            mounted.settle()
            try await WindowCapture.waitForFrames(
                of: mounted.window, spanning: FindIndicatorView.popDuration)
            let url = try await WindowCapture.capture(
                mounted.window, named: "FindPresentation-\(name)")
            add(XCTAttachment(contentsOfFile: url))
        }
    }
}

/// Answers rows from a fixed list.
@MainActor
private final class SnapshotHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private let rows: [TranscriptRow]

    init(rows: [TranscriptRowContent]) {
        self.rows = rows.map { TranscriptRow(id: UUID(), content: $0) }
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row]
    }
}

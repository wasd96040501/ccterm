import AppKit
import XCTest

@testable import TranscriptKit

/// Code cards as the window server composited them, in both appearances:
/// `/tmp/transcriptkit-screenshots/CodeBlock-{light,dark}.png`.
///
/// **For eyes, not a gate.** Skipped by `make test-kit`; run it with
/// `make test-kit FILTER=CodeBlockSnapshotTests` and open the two files. What it
/// is for is what `CodeBlockTests` cannot have an opinion on: that the card reads
/// as a surface on the window's own material rather than on a grey a test made
/// up, and that a first line wrapped short of the chip still reads as code. Both
/// halves of that — the contrast against any page, and no ink under the chip —
/// are asserted there.
///
/// Cards are chosen for where the chip can land: beside a line that runs into
/// it, beside one that stops short, on a card with no chip, and inside a quote.
@MainActor
final class CodeBlockSnapshotTests: XCTestCase {

    func testCodeBlocks() async throws {
        let host = Host(rows: [
            .markdown(
                """
                A first line long enough to reach the chip wraps short of it:

                ```swift
                return MarkdownBlockBuilder.make(source).measure(contentWidth).size.height
                ```

                One that stops short is laid out as if there were no chip:

                ```swift
                func height(ofRow row: Int) -> CGFloat {
                    rowCache.height(for: dataSource.transcriptView(self, rowAt: row), width: contentWidth)
                }
                ```

                A bare fence has no chip:

                ```
                make test-kit FILTER=CodeBlockSnapshotTests
                ```

                > And a card nests in a quote:
                >
                > ```bash
                > open /tmp/transcriptkit-screenshots/CodeBlock-light.png /tmp/transcriptkit-screenshots/CodeBlock-dark.png
                > ```
                """)
        ])
        let mounted = MountedTranscript(size: NSSize(width: 720, height: 640))
        defer { mounted.teardown() }
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.maxContentWidth = 620
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            mounted.window.appearance = NSAppearance(named: appearance)
            mounted.settle()
            let url = try await WindowCapture.capture(mounted.window, named: "CodeBlock-\(name)")
            add(XCTAttachment(contentsOfFile: url))
        }
    }
}

/// Answers rows from a fixed list.
@MainActor
private final class Host: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private let rows: [TranscriptRow]

    init(rows: [TranscriptRowContent]) {
        self.rows = rows.map { TranscriptRow(id: UUID(), content: $0) }
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row]
    }
}

import AppKit
import XCTest

@testable import TranscriptKit

/// A press on a host's `.view` row: the row acts on it in `mouseDown`, and
/// handing the event on with `super` gives the transcript focus — which is
/// how the keys that follow (↑ / ↓) reach it. A double-click reaches the
/// row as one, the tracking loop in between notwithstanding.
@MainActor
final class HostedViewPressTests: XCTestCase {

    /// A row that records each press and hands it on.
    private final class PressView: NSView {
        private(set) var clickCounts: [Int] = []

        override func mouseDown(with event: NSEvent) {
            clickCounts.append(event.clickCount)
            super.mouseDown(with: event)
        }
    }

    private final class Host: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {
        func numberOfRows(in transcriptView: TranscriptView) -> Int { 3 }

        func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
            TranscriptRow(id: row, content: .view)
        }

        func transcriptView(_ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
            40
        }

        func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
            transcriptView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("press")) { PressView() }
        }
    }

    private func press(_ mounted: MountedTranscript, _ view: NSView, clicks: Int) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(CGPoint(x: 10, y: 10), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: 1)!
        mounted.press(view, with: down)
    }

    func testAPressOnAHostedRowReachesItAndFocusesTheTranscript() throws {
        let mounted = MountedTranscript(size: NSSize(width: 800, height: 600))
        defer { mounted.teardown() }
        let host = Host()
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.reloadData()
        mounted.settle()
        let row = try XCTUnwrap(mounted.transcript.descendants(ofType: PressView.self).first)
        mounted.window.makeFirstResponder(nil)

        press(mounted, row, clicks: 1)
        XCTAssertTrue(
            mounted.window.firstResponder is NSTableView, "\(String(describing: mounted.window.firstResponder))")

        press(mounted, row, clicks: 2)
        XCTAssertEqual(row.clickCounts, [1, 2])
    }
}

import AppKit
import XCTest

@testable import TranscriptKit

/// The whole chain a host runs for a floating input bar, read off the window
/// server: the bar sits over a full-bleed transcript, grows, and its controller
/// writes the new height into `contentInsets`. The transcript's frame never
/// changes — only its scroll does — and the last row comes to rest above the bar.
@MainActor
final class InputBarInsetTests: XCTestCase {

    /// Rows of flat colour so a pixel says which row it is: the last one red,
    /// the rest grey.
    private final class ColorHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {
        private let ids = (0..<100).map { _ in UUID() }

        func numberOfRows(in transcriptView: TranscriptView) -> Int { ids.count }

        func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
            TranscriptRow(id: ids[row], content: .view)
        }

        func transcriptView(
            _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
        ) -> CGFloat { 40 }

        func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
            let view = transcriptView.makeView(withIdentifier: .colorRow) { NSView() }
            view.wantsLayer = true
            view.layer?.backgroundColor = (row == ids.count - 1 ? NSColor.red : .gray).cgColor
            return view
        }
    }

    func testAGrowingBarLiftsTheLastRowAboveIt() async throws {
        let mounted = MountedTranscript(size: NSSize(width: 800, height: 720))
        defer { mounted.teardown() }
        let root = try XCTUnwrap(mounted.window.contentView)
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.blue.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        let barHeight = bar.heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            barHeight,
        ])

        let host = ColorHost()
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.contentInsets.bottom = bar.frame.height
        mounted.transcript.reloadData()
        mounted.transcript.scrollToRow(at: 99, scrollPosition: .bottom)
        mounted.settle()
        let frame = mounted.transcript.frame
        XCTAssertEqual(frame, root.bounds, "the transcript is not full-bleed under the bar")

        /// The colour `points` above the bar's top edge, as composited.
        func colorAbove(bar height: CGFloat, by points: CGFloat) async throws -> NSColor {
            try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.1)
            let rep = try await WindowCapture.bitmap(of: mounted.transcript)
            let y = Int(rep.pixelsHigh) - Int(height + points)
            return try XCTUnwrap(rep.colorAt(x: 400, y: y)?.usingColorSpace(.sRGB))
        }
        let resting = try await colorAbove(bar: 60, by: 20)
        XCTAssertGreaterThan(resting.redComponent, 0.9, "the last row does not rest above the bar")
        XCTAssertLessThan(resting.greenComponent, 0.1)

        // The bar grows; its controller writes the new height into the inset.
        barHeight.constant = 140
        mounted.settle()
        mounted.transcript.contentInsets.bottom = bar.frame.height
        mounted.settle()

        XCTAssertEqual(mounted.transcript.frame, frame, "the transcript moved instead of its scroll")
        let lifted = try await colorAbove(bar: 140, by: 20)
        XCTAssertGreaterThan(lifted.redComponent, 0.9, "the last row went under the grown bar")
        XCTAssertLessThan(lifted.greenComponent, 0.1)
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let colorRow = NSUserInterfaceItemIdentifier("test.colorRow")
}

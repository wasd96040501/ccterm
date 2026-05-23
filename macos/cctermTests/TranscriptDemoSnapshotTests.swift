import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Validates the `ViewSnapshot` scaffold by rendering the real
/// `TranscriptDemoViewController` — the same VC the side-branch
/// mount path inserts when the user picks the "Transcript Demo"
/// sidebar item — and asserting the resulting bitmap has plausible
/// content.
///
/// The VC's seed step is gated on `controller.blockCount == 0`, so
/// the test pre-seeds a controller (matching the live demo's seed
/// payload byte-for-byte: `TranscriptDemoViewController.initialBlocks`
/// + the running-tool status puts) and passes it to the VC via the
/// test-seam init.
@MainActor
final class TranscriptDemoSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTranscriptDemoSnapshot() throws {
        let controller = Transcript2Controller()
        controller.setHistory(TranscriptDemoViewController.initialBlocks)
        controller.setToolStatus(
            id: TranscriptDemoViewController.runningGroupBlockId, status: .running)
        controller.setToolStatus(
            id: TranscriptDemoViewController.runningReadChildId, status: .completed)
        controller.setToolStatus(
            id: TranscriptDemoViewController.runningGrepChildId, status: .completed)
        controller.setToolStatus(
            id: TranscriptDemoViewController.runningBashChildId, status: .running)

        let vc = TranscriptDemoViewController(
            controller: controller, syntaxEngine: SyntaxHighlightEngine())

        let image = ViewSnapshot.renderViewController(
            vc, size: CGSize(width: 720, height: 720), settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "TranscriptDemoView")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "TranscriptDemoView.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(
            image.size.width >= 700 && image.size.height >= 700,
            "snapshot too small: \(image.size)")

        let bitmap: NSBitmapImageRep? = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .first
        guard let bitmap else {
            XCTFail("snapshot has no bitmap representation")
            return
        }

        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertFalse(
            isUniform(bitmap),
            "snapshot is a single flat color — view likely did not render")
    }

    /// Cheap "did anything draw?" check: probe a handful of widely-
    /// spaced pixels and confirm at least two of them differ. A
    /// single flat color is the canonical "view never rendered"
    /// failure mode for this scaffold.
    private func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 4, h > 4 else { return true }
        let probes: [(Int, Int)] = [
            (w / 4, h / 4),
            (w / 2, h / 4),
            (3 * w / 4, h / 4),
            (w / 4, h / 2),
            (w / 2, h / 2),
            (3 * w / 4, h / 2),
            (w / 4, 3 * h / 4),
            (w / 2, 3 * h / 4),
            (3 * w / 4, 3 * h / 4),
        ]
        let colors = probes.compactMap { rep.colorAt(x: $0.0, y: $0.1) }
        guard let first = colors.first else { return true }
        return colors.allSatisfy { $0 == first }
    }
}

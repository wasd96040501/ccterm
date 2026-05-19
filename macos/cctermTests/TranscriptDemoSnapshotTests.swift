import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Validates the `ViewSnapshot` scaffold by rendering the real
/// `TranscriptDemoView` — the same view RootView2 mounts when the
/// "Transcript demo" sidebar item is selected — and asserting the
/// resulting bitmap has plausible content.
///
/// SwiftUI's `.task` modifier does not fire reliably inside an
/// offscreen hosted-test window (AppKit's appearance signals are
/// gated by visibility), so we use the supported test seam:
/// `TranscriptDemoView`'s `init(controller:)` overload accepts a
/// pre-seeded `Transcript2Controller`. The seeding payload
/// (`TranscriptDemoView.initialBlocks` + the running-tool status
/// puts) is identical to what the production `.task` closure would
/// have installed — so the snapshot reflects the same view the user
/// sees after the demo's normal cold-start.
@MainActor
final class TranscriptDemoSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTranscriptDemoSnapshot() throws {
        let controller = Transcript2Controller()
        controller.setHistory(TranscriptDemoView.initialBlocks)
        controller.setToolStatus(
            id: TranscriptDemoView.runningGroupBlockId, status: .running)
        controller.setToolStatus(
            id: TranscriptDemoView.runningReadChildId, status: .completed)
        controller.setToolStatus(
            id: TranscriptDemoView.runningGrepChildId, status: .completed)
        controller.setToolStatus(
            id: TranscriptDemoView.runningBashChildId, status: .running)

        let view =
            TranscriptDemoView(controller: controller)
            .environment(\.syntaxEngine, SyntaxHighlightEngine())

        let image = ViewSnapshot.render(
            view, size: CGSize(width: 720, height: 720), settle: 0.6)
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

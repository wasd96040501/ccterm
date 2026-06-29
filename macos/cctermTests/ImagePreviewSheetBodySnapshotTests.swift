import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot (opt-in; SKIPPED on the default `make test-unit` /
/// CI suite) for the transcript image-preview sheet body
/// (`ImagePreviewSheetBody`, migration plan §4.7). Renders the REAL
/// `ImagePreviewSheetViewController` the transcript path routes to, at the
/// transcript ideal envelope (880 × 660), so the aspect-fit image area, the
/// divider, and the trailing Done button can be eyeballed against the SwiftUI
/// `ImagePreviewSheetView` original.
///
/// To view:
///   make test-unit FILTER=ImagePreviewSheetBodySnapshotTests
///   open /tmp/ccterm-screenshots/ImagePreviewSheetBody.png
@MainActor
final class ImagePreviewSheetBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTranscriptImagePreviewBody() throws {
        // A recognizable non-uniform fixture so the aspect-fit + padding are
        // visible (a wide bitmap fits to the window width, leaving top/bottom
        // letterbox bands inside the 24pt inset).
        let fixture = Self.makeFixtureImage(
            size: NSSize(width: 480, height: 200))

        let vc = ImagePreviewSheetBody.makeTranscriptViewController(image: fixture) {}

        let image = ViewSnapshot.renderViewController(
            vc, size: CGSize(width: 880, height: 660))
        let url = ViewSnapshot.writePNG(image, name: "ImagePreviewSheetBody")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "ImagePreviewSheetBody.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 800)
    }

    /// A two-tone bitmap (blue field with a red diagonal) so the snapshot is
    /// obviously non-uniform and the fit/letterbox geometry reads clearly.
    private static func makeFixtureImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 8
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: size.width, y: size.height))
        path.stroke()
        image.unlockFocus()
        return image
    }
}

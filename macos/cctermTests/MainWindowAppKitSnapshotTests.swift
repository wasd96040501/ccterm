import AppKit
import XCTest

@testable import ccterm

/// Renders the AppKit-rooted main window's content (the sidebar/detail
/// split) into an offscreen NSWindow, captures a PNG, and attaches it to
/// the xcresult.
///
/// Like the other snapshot tests in this target, the test is review-only —
/// no golden-image gate. `make test-unit` skips this class unless
/// explicitly filtered in
/// (`make test-unit FILTER=MainWindowAppKitSnapshotTests`).
@MainActor
final class MainWindowAppKitSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMainSplitSnapshot() throws {
        let size = CGSize(width: 1200, height: 800)
        let image = ViewSnapshot.renderViewController(
            MainSplitViewController(), size: size, settle: 1.0)

        let url = ViewSnapshot.writePNG(image, name: "MainWindowAppKit-MainSplit")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "MainWindowAppKit-MainSplit.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }
}

import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot (opt-in; SKIPPED on the unfiltered CI gate) for the
/// pure-AppKit `UserBubbleSheetViewController` (migration plan §4.7). Renders
/// the real production VC via `ViewSnapshot.renderViewController` so the
/// selectable text body + divider + trailing Done button can be eyeballed
/// against the deleted SwiftUI `UserBubbleSheetView`.
///
/// Not a regression gate — `make test-unit FILTER=UserBubbleSheetBodySnapshotTests`
/// then `open /tmp/ccterm-screenshots/UserBubbleSheetBody*.png`.
@MainActor
final class UserBubbleSheetBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func render(_ text: String, name: String, size: CGSize) {
        let vc = UserBubbleSheetViewController(text: text, onDismiss: {})
        let image = ViewSnapshot.renderViewController(vc, size: size)
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    func testShortText() {
        render(
            "Refactor the transcript detail page to pure AppKit.",
            name: "UserBubbleSheetBody-short",
            size: CGSize(width: 720, height: 540))
    }

    func testLongText() {
        let long = String(
            repeating:
                "This is a long user bubble whose full text overflows the visible "
                + "transcript bubble and is shown here in a scrollable, selectable "
                + "text view. ",
            count: 40)
        render(
            long,
            name: "UserBubbleSheetBody-long",
            size: CGSize(width: 720, height: 540))
    }
}

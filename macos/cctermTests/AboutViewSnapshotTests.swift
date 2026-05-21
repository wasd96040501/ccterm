import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Visual review for the custom "About ccterm" panel. Renders the
/// view through `NSHostingController` so what we see here matches what
/// the user gets when they pick App menu → About ccterm.
///
/// Opt-in (filename ends in `SnapshotTests`); see cctermTests/CLAUDE.md.
@MainActor
final class AboutViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDefaultRender() throws {
        let size = CGSize(width: 320, height: 220)
        let view = AboutView()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: size, settle: 0.4)
        let url = ViewSnapshot.writePNG(image, name: "AboutView")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "AboutView.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }
}

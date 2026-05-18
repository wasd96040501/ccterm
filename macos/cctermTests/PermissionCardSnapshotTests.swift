import AgentSDK
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders `PermissionCardView` in isolation and writes a PNG so the
/// card layout can be reviewed without launching the app. This is the
/// Step 0 scaffold — captures the stub surface. Follow-up commits in
/// this PR fill in the full layout and decision buttons; the test
/// keeps tracking the same fixture so PR reviewers can scrub the PNG
/// across commits.
@MainActor
final class PermissionCardSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBashRequestSnapshot() throws {
        let request = PermissionRequest.makePreview(
            requestId: "req-1",
            toolName: "Bash",
            input: ["command": "rm -rf node_modules", "description": "Reset deps"])

        let view = PermissionCardFixture(request: request)
            .frame(width: 520, height: 220)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: CGSize(width: 520, height: 220), settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "PermissionCard-Bash")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "PermissionCard-Bash.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 519)
    }
}

/// Wraps the card with the same horizontal padding the chrome lives
/// under in production, so the snapshot reads as a fair preview of
/// the card's real geometry — not just the card on a transparent
/// canvas.
private struct PermissionCardFixture: View {
    let request: PermissionRequest

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            PermissionCardView(
                request: request,
                onAllowOnce: {},
                onAllowAlways: {},
                onDeny: {}
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

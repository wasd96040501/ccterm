import AppKit
import XCTest

@testable import ccterm

/// Snapshot for the AppKit-native sidebar (`SidebarViewController`). The
/// previous SwiftUI sidebar test composed individual row types into a
/// `VStack` because `.listStyle(.sidebar)` refused to render under the
/// offscreen XCTest window; the AppKit `NSOutlineView` has no such
/// limitation, so we can mount the real controller and capture the
/// production layout end-to-end.
///
/// The PNG is attached to the xcresult for human review; there is no
/// golden-image comparison. Open `/tmp/ccterm-screenshots/SidebarView2.png`
/// after running.
@MainActor
final class SidebarView2SnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSidebarStateIndicators() throws {
        let repo = InMemorySessionRepository()

        // Records mirror what the production sidebar groups by:
        // `groupingFolderName` from `originPath`. Two folders × a mix of
        // indicator states so every visual branch is on screen.
        let now = Date()
        let runningInProjectA = makeRecord(
            title: "Refactor login screen",
            originPath: "/Users/me/work/project-a",
            lastActiveAt: now)
        let unreadInProjectA = makeRecord(
            title: "Investigate flaky test",
            originPath: "/Users/me/work/project-a",
            lastActiveAt: now.addingTimeInterval(-60))
        let idleInProjectA = makeRecord(
            title: "Notes & TODOs",
            originPath: "/Users/me/work/project-a",
            lastActiveAt: now.addingTimeInterval(-120))
        let runningAndUnreadInProjectB = makeRecord(
            title: "Deploy pipeline",
            originPath: "/Users/me/work/project-b",
            lastActiveAt: now.addingTimeInterval(-30))
        let idleInProjectB = makeRecord(
            title: "Read-only browsing",
            originPath: "/Users/me/work/project-b",
            lastActiveAt: now.addingTimeInterval(-180))

        for record in [
            runningInProjectA, unreadInProjectA, idleInProjectA,
            runningAndUnreadInProjectB, idleInProjectB,
        ] {
            repo.save(record)
        }

        let manager = SessionManager(repository: repo)

        // Drive runtime indicator state directly: `isRunning` /
        // `hasUnread` are `internal(set)` on `SessionRuntime`, reached
        // via `@testable import`. Records without a runtime show no
        // indicator (matches production behavior for sessions never
        // activated in this process lifetime).
        let running = try XCTUnwrap(manager.session(runningInProjectA.sessionId)?.runtime)
        running.isRunning = true

        let unread = try XCTUnwrap(manager.session(unreadInProjectA.sessionId)?.runtime)
        unread.hasUnread = true

        let both = try XCTUnwrap(manager.session(runningAndUnreadInProjectB.sessionId)?.runtime)
        both.isRunning = true
        both.hasUnread = true

        let model = MainSelectionModel()
        let controller = SidebarViewController(model: model, sessionManager: manager)

        let image = ViewSnapshot.render(
            controller: controller,
            size: CGSize(width: 260, height: 360),
            settle: 0.8)
        let url = ViewSnapshot.writePNG(image, name: "SidebarView2")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "SidebarView2.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 240)
        XCTAssertGreaterThanOrEqual(image.size.height, 320)
    }

    private func makeRecord(
        title: String,
        originPath: String,
        lastActiveAt: Date
    ) -> SessionRecord {
        SessionRecord(
            sessionId: UUID().uuidString.lowercased(),
            title: title,
            cwd: originPath,
            originPath: originPath,
            lastActiveAt: lastActiveAt,
            status: .created
        )
    }
}

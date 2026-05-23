import AppKit
import XCTest

@testable import ccterm

/// Snapshot for the AppKit-native sidebar (`SidebarViewController`).
/// Now that the sidebar is rooted in `NSOutlineView` (not a SwiftUI
/// `.listStyle(.sidebar)` that refuses to render offscreen), the test
/// mounts the real controller and captures the production layout end-
/// to-end — fixed tabs, folder headers with right-side chevron, and
/// per-row status indicators (running dots / unread dot).
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
        // Long Chinese title — reproduces the real-world bug where a
        // session title overflows the sidebar column. Must render as
        // ONE line with a tail ellipsis (`…`); MUST NOT wrap, and MUST
        // NOT stretch the row height past `historyRowHeight = 22pt`.
        let longChineseInProjectA = makeRecord(
            title: "我想给我们的 7 层网关系统加一个限流中间件，他都有哪些功能模块需要修改？",
            originPath: "/Users/me/work/project-a",
            lastActiveAt: now.addingTimeInterval(-30))
        // Combined "weird" title — newlines, tabs, leading/trailing
        // whitespace, a zero-width space, and a U+FFFC object
        // replacement character. Reproduces the title-from-first-
        // message case where the user's prompt was multi-paragraph
        // and/or pasted from a rich source. The cell has to collapse
        // these into a single visually-clean line, or the row blows
        // past its `heightOfRowByItem` and bleeds into neighbors.
        let weirdInProjectA = makeRecord(
            title:
                "  Investigate\nthe\tfailing deploy\u{200B} pipeline\u{FFFC} across all regions  ",
            originPath: "/Users/me/work/project-a",
            lastActiveAt: now.addingTimeInterval(-20))
        let unreadInProjectA = makeRecord(
            title: "Investigate flaky test",
            originPath: "/Users/me/work/project-a",
            lastActiveAt: now.addingTimeInterval(-60))
        let idleInProjectA = makeRecord(
            title: "Notes & TODOs",
            originPath: "/Users/me/work/project-a",
            lastActiveAt: now.addingTimeInterval(-120))
        // Long English title — second representative overflow case to
        // make sure the ellipsis lands on a word boundary cleanly.
        let longEnglishInProjectB = makeRecord(
            title:
                "Investigate the failing deploy pipeline and rerun the canary across all regions",
            originPath: "/Users/me/work/project-b",
            lastActiveAt: now.addingTimeInterval(-15))
        let runningAndUnreadInProjectB = makeRecord(
            title: "Deploy pipeline",
            originPath: "/Users/me/work/project-b",
            lastActiveAt: now.addingTimeInterval(-30))
        let idleInProjectB = makeRecord(
            title: "Read-only browsing",
            originPath: "/Users/me/work/project-b",
            lastActiveAt: now.addingTimeInterval(-180))

        for record in [
            runningInProjectA, longChineseInProjectA, weirdInProjectA, unreadInProjectA,
            idleInProjectA,
            longEnglishInProjectB, runningAndUnreadInProjectB, idleInProjectB,
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

        // Per cctermTests/CLAUDE.md rule #3: no UserDefaults.standard
        // reads/writes from tests. Hand the store an isolated
        // UserDefaults so the snapshot can't leak across parallel test
        // classes.
        let defaults = UserDefaults(suiteName: "ccterm.sidebar.snapshot.\(UUID().uuidString)")!
        let groupOrderStore = SidebarSessionGroupOrderStore(defaults: defaults)
        let model = MainSelectionModel()
        let controller = SidebarViewController(
            model: model,
            sessionManager: manager,
            groupOrderStore: groupOrderStore)

        let image = ViewSnapshot.renderViewController(
            controller,
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

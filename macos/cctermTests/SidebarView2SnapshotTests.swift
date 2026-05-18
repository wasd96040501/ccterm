import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Snapshot for the sidebar's history-row chrome plus the runtime-state
/// indicators added to each row (three breathing dots when the session
/// is running, a small blue dot when unread, both hidden otherwise).
///
/// `SidebarView2` itself is rendered through SwiftUI's
/// `.listStyle(.sidebar)`, which is backed by `NSOutlineView` and
/// refuses to lay out rows in an offscreen test window — so the full
/// view comes out blank. The view's individual row types are exposed
/// at internal access purely so this test can compose them into a
/// `VStack` and visualize the indicator slot. Production wiring is
/// unchanged (production still goes through `SidebarView2`'s List).
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

        // Allocate sessions via the public surface and drive observable
        // state directly through the underlying runtime. `pendingTurnCount`
        // and `hasUnread` are `internal(set)` on `SessionRuntime` —
        // `@testable import` lets the test reach them without adding
        // production-only seams. `session(_:)` returns a façade in
        // `.active` phase for any record-existing id, so `runtime` is
        // non-nil here.
        let running = try XCTUnwrap(manager.session(runningInProjectA.sessionId)?.runtime)
        running.pendingTurnCount = 1

        let unread = try XCTUnwrap(manager.session(unreadInProjectA.sessionId)?.runtime)
        unread.hasUnread = true

        let both = try XCTUnwrap(manager.session(runningAndUnreadInProjectB.sessionId)?.runtime)
        both.pendingTurnCount = 1
        both.hasUnread = true

        // `idleInProjectA` / `idleInProjectB` deliberately have no
        // handle — sidebar reads them via `existingSession` and shows no
        // indicator, matching production behavior for sessions never
        // activated in this process lifetime.

        // Compose the same rows the production List would, in a plain
        // VStack with sidebar-style padding. Backgrounded with
        // `windowBackgroundColor` so the secondary-label text reads.
        let preview = VStack(alignment: .leading, spacing: 0) {
            SidebarItemRow(
                title: "New Session", systemImage: "square.and.pencil"
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            SidebarItemRow(
                title: "Transcript Demo", systemImage: "doc.text.image"
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            SidebarFolderHeader(
                name: "project-a", isExpanded: true, onToggle: {}
            )
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)

            SidebarHistoryRow(record: runningInProjectA)
                .padding(.horizontal, 8).padding(.vertical, 1)
            SidebarHistoryRow(record: unreadInProjectA)
                .padding(.horizontal, 8).padding(.vertical, 1)
            SidebarHistoryRow(record: idleInProjectA)
                .padding(.horizontal, 8).padding(.vertical, 1)

            SidebarFolderHeader(
                name: "project-b", isExpanded: true, onToggle: {}
            )
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)

            SidebarHistoryRow(record: runningAndUnreadInProjectB)
                .padding(.horizontal, 8).padding(.vertical, 1)
            SidebarHistoryRow(record: idleInProjectB)
                .padding(.horizontal, 8).padding(.vertical, 1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(manager)

        let image = ViewSnapshot.render(
            preview, size: CGSize(width: 260, height: 360), settle: 0.8)
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

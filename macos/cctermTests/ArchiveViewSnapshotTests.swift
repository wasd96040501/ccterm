import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Snapshot review for `ArchiveView` — exercises both the empty state
/// and the populated list at a realistic window width so the title
/// truncation, two-line metadata strip, and trailing "Unarchive" pill
/// can all be eyeballed in one PNG.
///
/// Unlike the sidebar snapshot (which has to compose row primitives by
/// hand because `.listStyle(.sidebar)` won't render offscreen),
/// `ArchiveView` uses a plain `ScrollView` + `LazyVStack` and renders
/// faithfully in the hosted-test window. We render the full view to
/// keep the test honest: spacing, headers, dividers, and the centered
/// column width clamp are all part of the artifact.
///
/// Run:
///
/// ```bash
/// make test-unit FILTER=ArchiveViewSnapshotTests
/// open /tmp/ccterm-screenshots/ArchiveView.png
/// open /tmp/ccterm-screenshots/ArchiveViewEmpty.png
/// ```
@MainActor
final class ArchiveViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Populated archive: mix of plain folder + worktree rows, short +
    /// long titles, varied "archived" times so the relative-date column
    /// shows multiple flavors. The snapshot ought to read as a
    /// restrained, breathable two-line-per-row column with the
    /// "Unarchive" pill always visible.
    func testPopulatedArchive() throws {
        let repo = InMemorySessionRepository()
        let now = Date()
        let records: [SessionRecord] = [
            makeArchived(
                title: "Refactor login screen authentication flow",
                originPath: "/Users/me/work/project-a",
                isWorktree: true,
                worktreeBranch: "eager-curie-abc123",
                archivedAt: now.addingTimeInterval(-60)),
            makeArchived(
                title: "Investigate flaky integration test",
                originPath: "/Users/me/work/project-a",
                archivedAt: now.addingTimeInterval(-3 * 3600)),
            makeArchived(
                title: "Notes & TODOs",
                originPath: "/Users/me/work/project-b",
                archivedAt: now.addingTimeInterval(-2 * 86400)),
            makeArchived(
                title: "",  // Untitled fallback path
                originPath: "/Users/me/work/project-c",
                archivedAt: now.addingTimeInterval(-7 * 86400)),
            makeArchived(
                title: "Deploy pipeline tuning",
                originPath: "/Users/me/work/project-b",
                isWorktree: true,
                worktreeBranch: "jolly-pare-d40302",
                archivedAt: now.addingTimeInterval(-14 * 86400)),
        ]
        for record in records { repo.save(record) }

        let manager = SessionManager2(
            repository: repo,
            worktreeArchive: { _ in },
            worktreeRestore: { _ in })
        manager.refreshArchivedRecords()

        let preview = ArchiveView(onUnarchive: { _ in })
            .environment(manager)

        // 820 wide × 720 tall: gives the centered column the
        // 760pt-max breathing room plus the empty rails.
        let image = ViewSnapshot.render(preview, size: CGSize(width: 820, height: 720), settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "ArchiveView")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "ArchiveView.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 800)
        XCTAssertGreaterThanOrEqual(image.size.height, 700)
    }

    /// Empty archive: icon + headline + supporting text, centered.
    /// Confirms the empty path is reachable and visually balanced
    /// (it's the first thing every new user sees).
    func testEmptyArchive() throws {
        let manager = SessionManager2(
            repository: InMemorySessionRepository(),
            worktreeArchive: { _ in },
            worktreeRestore: { _ in })

        let preview = ArchiveView(onUnarchive: { _ in })
            .environment(manager)

        let image = ViewSnapshot.render(preview, size: CGSize(width: 820, height: 520), settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "ArchiveViewEmpty")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "ArchiveViewEmpty.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 800)
    }

    private func makeArchived(
        title: String,
        originPath: String,
        isWorktree: Bool = false,
        worktreeBranch: String? = nil,
        archivedAt: Date
    ) -> SessionRecord {
        SessionRecord(
            sessionId: UUID().uuidString.lowercased(),
            title: title,
            cwd: isWorktree
                ? "\(originPath)/.claude/worktrees/\(worktreeBranch ?? "wt")"
                : originPath,
            isWorktree: isWorktree,
            originPath: originPath,
            createdAt: archivedAt,
            lastActiveAt: archivedAt,
            status: .archived,
            archivedAt: archivedAt,
            worktreeBranch: worktreeBranch
        )
    }
}

import AgentSDK
import XCTest

@testable import ccterm

/// `SessionManager.createSidebarDraft` + the draft-surfacing lifecycle:
/// metadata seeding, the in-memory `draftRecords` row, prune-on-promotion,
/// and cleanup-on-archive — the storage half of the `/new` and `/clear`
/// builtins.
@MainActor
final class SessionManagerDraftTests: XCTestCase {

    private func makeManager() -> SessionManager {
        SessionManager(
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
    }

    func test_createSidebarDraft_seedsMetadataFromSource() {
        let manager = makeManager()
        let source = manager.prepareDraftSession("src")
        source.draft?.setCwd("/proj")
        source.draft?.setOriginPath("/proj")
        source.draft?.setWorktree(true)
        source.draft?.setSourceBranch("main")
        source.setModel("opus")

        let draftId = manager.createSidebarDraft(seededFrom: "src")
        let draft = manager.existingSession(draftId)

        XCTAssertEqual(draft?.cwd, "/proj")
        XCTAssertEqual(draft?.originPath, "/proj")
        XCTAssertEqual(draft?.isWorktree, true)
        XCTAssertEqual(draft?.sourceBranch, "main")
        XCTAssertEqual(draft?.model, "opus")
        XCTAssertTrue(draft?.isDraft == true)
    }

    func test_createSidebarDraft_worktreeSource_seedsCwdFromOriginNotWorktreeDir() {
        // For a worktree source, source.cwd is the PROVISIONED worktree dir.
        // The new draft must seed cwd from originPath (the base repo) so its
        // landing page shows the repo — not the old worktree — and promotion
        // provisions a fresh worktree from the base.
        let manager = makeManager()
        let source = manager.prepareDraftSession("wt-src")
        source.draft?.setOriginPath("/repo")
        source.draft?.setCwd("/repo/.ccterm-worktrees/oldname")
        source.draft?.setWorktree(true)
        source.draft?.setSourceBranch("main")

        let draftId = manager.createSidebarDraft(seededFrom: "wt-src")
        let draft = manager.existingSession(draftId)

        XCTAssertEqual(draft?.cwd, "/repo", "worktree draft cwd must be the base repo, not the source worktree dir")
        XCTAssertEqual(draft?.originPath, "/repo")
        XCTAssertEqual(draft?.isWorktree, true)
        XCTAssertNil(draft?.worktreeBranch, "the fresh worktree name is generated at first send, not copied")
    }

    func test_createSidebarDraft_addsSidebarRow() {
        let manager = makeManager()
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        let record = manager.draftRecords.first { $0.sessionId == draftId }
        XCTAssertNotNil(record)
        // Empty title → rendered as "Untitled" by the sidebar.
        XCTAssertEqual(record?.title, "")
        XCTAssertEqual(record?.status, .pending)
    }

    func test_createSidebarDraft_withoutSource_isUnseeded() {
        let manager = makeManager()
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        let draft = manager.existingSession(draftId)
        XCTAssertNil(draft?.cwd)
        XCTAssertEqual(draft?.isWorktree, false)
    }

    func test_refreshRecords_prunesPromotedDraft() {
        let manager = makeManager()
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        XCTAssertTrue(manager.draftRecords.contains { $0.sessionId == draftId })

        // First message promotes the draft → a persisted record appears and
        // the in-memory draft row is pruned in the same beat.
        manager.prepareDraftSession(draftId).send(text: "hello")

        XCTAssertTrue(manager.records.contains { $0.sessionId == draftId })
        XCTAssertFalse(manager.draftRecords.contains { $0.sessionId == draftId })
    }

    func test_archive_removesUnsentDraft() {
        let manager = makeManager()
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        XCTAssertTrue(manager.draftRecords.contains { $0.sessionId == draftId })

        // Archiving an unsent draft (no persisted record) still drops the
        // in-memory sidebar row — covers the `/clear`-then-abandon path.
        manager.archive(draftId)
        XCTAssertFalse(manager.draftRecords.contains { $0.sessionId == draftId })
    }

    func test_chainedDraft_seedsFromDraftSource() {
        // `/new` triggered from a session that is itself still a draft.
        // `session(_:)` materializes a façade for the draft source so the
        // copy reads its config rather than crashing on a nil lookup.
        let manager = makeManager()
        let first = manager.createSidebarDraft(seededFrom: nil)
        manager.existingSession(first)?.draft?.setCwd("/a")
        let second = manager.createSidebarDraft(seededFrom: first)
        XCTAssertEqual(manager.existingSession(second)?.cwd, "/a")
    }
}

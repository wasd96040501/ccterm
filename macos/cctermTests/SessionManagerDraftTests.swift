import AgentSDK
import XCTest

@testable import ccterm

/// `SessionManager.createSidebarDraft` + the persisted-`.draft` lifecycle:
/// adopt seeding (incl. worktree reuse), the durable `.draft` sidebar row,
/// in-place promotion, hard-delete-on-dismiss, restart survival, and the
/// reference-counted worktree teardown — the storage half of `/new` and
/// `/clear`.
@MainActor
final class SessionManagerDraftTests: XCTestCase {

    private func makeManager(
        repository: InMemorySessionRepository,
        worktreeArchive: @escaping SessionManager.WorktreeSideEffect = { _ in }
    ) -> SessionManager {
        SessionManager(
            repository: repository,
            cliClientFactory: { _ in FakeCLIClient() },
            worktreeArchive: worktreeArchive,
            worktreeRestore: { _ in }
        )
    }

    // MARK: - Seeding

    func test_createSidebarDraft_seedsMetadataFromSource() {
        let manager = makeManager(repository: InMemorySessionRepository())
        let source = manager.prepareDraftSession("src")
        source.draft?.setCwd("/proj")
        source.draft?.setOriginPath("/proj")
        source.draft?.setSourceBranch("main")
        source.setModel("opus")

        let draftId = manager.createSidebarDraft(seededFrom: "src")
        let draft = manager.existingSession(draftId)

        XCTAssertEqual(draft?.cwd, "/proj")
        XCTAssertEqual(draft?.originPath, "/proj")
        XCTAssertEqual(draft?.sourceBranch, "main")
        XCTAssertEqual(draft?.model, "opus")
        XCTAssertTrue(draft?.isDraft == true)
    }

    /// Worktree reuse (the user-reported fix): the new draft adopts the
    /// source's ACTUAL worktree dir and its provisioned branch so it continues
    /// in the same worktree — it does NOT seed the base repo and fork a fresh
    /// one.
    func test_createSidebarDraft_worktreeSource_adoptsWorktreeDirAndBranch() {
        let manager = makeManager(repository: InMemorySessionRepository())
        let source = manager.prepareDraftSession("wt-src")
        source.draft?.setOriginPath("/repo")
        source.draft?.setCwd("/repo/.claude/worktrees/oldname")
        source.draft?.setWorktree(true)
        source.draft?.setSourceBranch("main")
        source.draft?.setWorktreeBranch("oldname")

        let draftId = manager.createSidebarDraft(seededFrom: "wt-src")
        let draft = manager.existingSession(draftId)

        XCTAssertEqual(
            draft?.cwd, "/repo/.claude/worktrees/oldname",
            "worktree draft must reuse the source worktree dir, not the base repo")
        XCTAssertEqual(
            draft?.worktreeBranch, "oldname",
            "the provisioned worktree branch is carried so the new session shares it")
        XCTAssertEqual(draft?.originPath, "/repo")
        XCTAssertEqual(draft?.isWorktree, true)
    }

    // MARK: - Persisted .draft row

    func test_createSidebarDraft_persistsDraftStatusRow() {
        let repo = InMemorySessionRepository()
        let manager = makeManager(repository: repo)
        let draftId = manager.createSidebarDraft(seededFrom: nil)

        let record = repo.find(draftId)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.status, .draft)
        // Empty title → rendered as "New Draft" by the sidebar.
        XCTAssertEqual(record?.title, "")
        XCTAssertTrue(manager.records.contains { $0.sessionId == draftId })
        XCTAssertTrue(manager.isDraftSession(draftId))
    }

    func test_createSidebarDraft_withoutSource_isUnseeded() {
        let manager = makeManager(repository: InMemorySessionRepository())
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        let draft = manager.existingSession(draftId)
        XCTAssertNil(draft?.cwd)
        XCTAssertEqual(draft?.isWorktree, false)
    }

    // MARK: - Restart survival

    /// A persisted `.draft` row survives an app restart: a fresh
    /// `SessionManager` over the same repo surfaces it as a sidebar row and
    /// resolves it to a DRAFT-phase façade (lands on the landing page,
    /// promotes on first send) — not an `.active` transcript.
    func test_draftRow_survivesRestart_asDraftPhase() {
        let repo = InMemorySessionRepository()
        let first = makeManager(repository: repo)
        let draftId = first.createSidebarDraft(seededFrom: nil)

        // Simulate relaunch: a brand-new manager with an empty session cache,
        // reading the same persisted store.
        let restarted = makeManager(repository: repo)
        XCTAssertTrue(restarted.records.contains { $0.sessionId == draftId })
        XCTAssertTrue(
            restarted.isDraftSession(draftId), "uncached .draft row must still read as a draft")
        XCTAssertTrue(
            restarted.prepareDraftSession(draftId).isDraft,
            "rehydrated façade must be draft-phase, not active")
    }

    // MARK: - Promotion (in-place status flip)

    func test_promotion_flipsDraftRowInPlace() {
        let repo = InMemorySessionRepository()
        let manager = makeManager(repository: repo)
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        XCTAssertTrue(manager.isDraftSession(draftId))

        // First message promotes: same row, no longer a draft.
        manager.prepareDraftSession(draftId).send(text: "hello")

        XCTAssertTrue(manager.records.contains { $0.sessionId == draftId })
        XCTAssertFalse(manager.isDraftSession(draftId))
        XCTAssertNotEqual(repo.find(draftId)?.status, .draft, "send must flip .draft off the record")
    }

    // MARK: - Dismiss

    /// Archiving a never-sent draft hard-deletes it (it vanishes; it does not
    /// surface on the Archive page) — preserving the old in-memory behavior.
    func test_archive_hardDeletesUnsentDraft() {
        let repo = InMemorySessionRepository()
        let manager = makeManager(repository: repo)
        let draftId = manager.createSidebarDraft(seededFrom: nil)

        manager.archive(draftId)

        XCTAssertNil(repo.find(draftId), "unsent draft must be hard-deleted")
        XCTAssertFalse(manager.records.contains { $0.sessionId == draftId })
        XCTAssertFalse(
            repo.findArchived().contains { $0.sessionId == draftId },
            "a dismissed draft must not appear on the Archive page")
    }

    // MARK: - Chained /new

    func test_chainedDraft_seedsFromDraftSource() {
        // `/new` triggered from a session that is itself still a draft.
        let manager = makeManager(repository: InMemorySessionRepository())
        let first = manager.createSidebarDraft(seededFrom: nil)
        manager.existingSession(first)?.draft?.setCwd("/a")
        let second = manager.createSidebarDraft(seededFrom: first)
        XCTAssertEqual(manager.existingSession(second)?.cwd, "/a")
    }

    // MARK: - Reference-counted worktree teardown

    /// `/clear` on a worktree session: the adopter is persisted (sharing the
    /// worktree branch) BEFORE the source is archived — the exact order
    /// `runBuiltinSlashCommand` uses — so archiving the source must NOT tear
    /// the worktree down. Archiving the last referencer (the adopter) does.
    func test_clearOnWorktree_keepsWorktreeUntilLastReferencerGone() {
        let repo = InMemorySessionRepository()
        let recorder = SideEffectRecorder()
        let manager = makeManager(repository: repo, worktreeArchive: recorder.record)

        let srcId = "wt-source"
        repo.save(
            SessionRecord(
                sessionId: srcId, title: "src",
                cwd: "/repo/.claude/worktrees/W", isWorktree: true,
                originPath: "/repo", status: .created, worktreeBranch: "W"))
        manager.refreshRecords()

        let adopterId = manager.createSidebarDraft(seededFrom: srcId)
        manager.archive(srcId)

        XCTAssertEqual(
            recorder.calls.count, 0,
            "worktree must survive archive while the adopter still references it")
        XCTAssertEqual(manager.existingSession(adopterId)?.worktreeBranch, "W")
        XCTAssertTrue(manager.isDraftSession(adopterId))
        XCTAssertFalse(manager.records.contains { $0.sessionId == srcId })

        // Adopter is a `.draft` → hard-deleted; refcount hits zero → teardown.
        manager.archive(adopterId)
        XCTAssertEqual(recorder.calls.count, 1, "last referencer gone → worktree removed once")
    }

    /// A single-owner worktree session still tears its worktree down on
    /// archive (no other referencer) — the refcount gate must not regress the
    /// common case.
    func test_archive_singleOwnerWorktree_tearsDown() {
        let repo = InMemorySessionRepository()
        let recorder = SideEffectRecorder()
        let manager = makeManager(repository: repo, worktreeArchive: recorder.record)
        let sid = "solo"
        repo.save(
            SessionRecord(
                sessionId: sid, title: "solo",
                cwd: "/repo/.claude/worktrees/S", isWorktree: true,
                originPath: "/repo", status: .created, worktreeBranch: "S"))
        manager.refreshRecords()

        manager.archive(sid)

        XCTAssertEqual(recorder.calls.count, 1)
    }

    // MARK: - Helpers

    private final class SideEffectRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [SessionRecord] = []
        func record(_ record: SessionRecord) {
            lock.lock()
            calls.append(record)
            lock.unlock()
        }
    }
}

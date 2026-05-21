import XCTest

@testable import ccterm

/// Core behavior of `SessionManager.archive` / `unarchive`: DB state
/// transitions, observable list maintenance, handle-cache cleanup, and
/// the worktree side-effect dispatch (verified via an injected
/// recorder closure — see the "WorktreeSideEffectRouting" suite at the
/// bottom).
///
/// All tests stand up an `InMemorySessionRepository` (DEBUG-only mock)
/// per case so they're parallel-safe; no test writes to disk or hits
/// real git.
@MainActor
final class SessionManagerArchiveTests: XCTestCase {

    private var repo: InMemorySessionRepository!

    override func setUpWithError() throws {
        continueAfterFailure = false
        repo = InMemorySessionRepository()
    }

    override func tearDownWithError() throws {
        repo = nil
    }

    // MARK: - Core archive

    /// Archive flips status, sets archivedAt, and drops the row out of
    /// the active records list (and into the archived list).
    func testArchiveFlipsStatusAndMovesRecord() {
        let sid = UUID().uuidString
        let record = makeRecord(sid: sid, title: "About to archive", status: .created)
        repo.save(record)
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)
        manager.refreshArchivedRecords()

        XCTAssertEqual(manager.records.count, 1)
        XCTAssertEqual(manager.archivedRecords.count, 0)

        manager.archive(sid)

        XCTAssertEqual(manager.records.count, 0, "Active record list must drop the archived session")
        XCTAssertEqual(manager.archivedRecords.count, 1, "Archived record list must include it")
        XCTAssertEqual(manager.archivedRecords.first?.sessionId, sid)
        XCTAssertEqual(manager.archivedRecords.first?.status, .archived)
        XCTAssertNotNil(manager.archivedRecords.first?.archivedAt)
    }

    /// Unarchive flips status back, clears archivedAt, and the record
    /// returns to the active list.
    func testUnarchiveFlipsStatusAndRestoresRecord() {
        let sid = UUID().uuidString
        let record = makeRecord(sid: sid, title: "Bring me back", status: .archived, archivedAt: Date())
        repo.save(record)
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)
        manager.refreshArchivedRecords()

        XCTAssertEqual(manager.records.count, 0)
        XCTAssertEqual(manager.archivedRecords.count, 1)

        manager.unarchive(sid)

        XCTAssertEqual(manager.records.count, 1, "Unarchived session must re-appear in the active list")
        XCTAssertEqual(manager.records.first?.status, .created)
        XCTAssertNil(manager.records.first?.archivedAt)
        XCTAssertEqual(manager.archivedRecords.count, 0, "Archived list must drop the unarchived session")
    }

    /// Archive then unarchive round-trip leaves the row in `.created`
    /// with the original metadata preserved (title, cwd, etc.).
    func testArchiveUnarchiveRoundTripPreservesMetadata() {
        let sid = UUID().uuidString
        let original = makeRecord(
            sid: sid,
            title: "Round trip",
            cwd: "/Users/me/projects/foo",
            originPath: "/Users/me/projects/foo",
            status: .created
        )
        repo.save(original)
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)

        manager.archive(sid)
        manager.unarchive(sid)

        let restored = manager.records.first
        XCTAssertEqual(restored?.sessionId, sid)
        XCTAssertEqual(restored?.title, "Round trip")
        XCTAssertEqual(restored?.cwd, "/Users/me/projects/foo")
        XCTAssertEqual(restored?.originPath, "/Users/me/projects/foo")
        XCTAssertEqual(restored?.status, .created)
        XCTAssertNil(restored?.archivedAt)
    }

    // MARK: - Boundary cases

    /// Archiving a sessionId that doesn't exist is a no-op: no crash,
    /// no spurious entries in `archivedRecords`.
    func testArchiveNonexistentSessionIsNoOp() {
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)
        manager.archive("does-not-exist")
        XCTAssertEqual(manager.records.count, 0)
        XCTAssertEqual(manager.archivedRecords.count, 0)
    }

    /// Unarchiving a sessionId that doesn't exist is a no-op.
    func testUnarchiveNonexistentSessionIsNoOp() {
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)
        manager.unarchive("does-not-exist")
        XCTAssertEqual(manager.records.count, 0)
        XCTAssertEqual(manager.archivedRecords.count, 0)
    }

    /// `refreshArchivedRecords` sorts descending by `archivedAt` (then
    /// `lastActiveAt`), matching `InMemorySessionRepository.findArchived`.
    /// Most recently archived must appear first.
    func testArchivedRecordsSortedNewestFirst() {
        let now = Date()
        let older = makeRecord(
            sid: "older",
            title: "Older archive",
            status: .archived,
            archivedAt: now.addingTimeInterval(-3600),
            lastActiveAt: now.addingTimeInterval(-3600)
        )
        let newer = makeRecord(
            sid: "newer",
            title: "Newer archive",
            status: .archived,
            archivedAt: now,
            lastActiveAt: now
        )
        repo.save(older)
        repo.save(newer)
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)
        manager.refreshArchivedRecords()

        XCTAssertEqual(manager.archivedRecords.map(\.sessionId), ["newer", "older"])
    }

    /// Once archived, `session(_:)` must not return a handle — the
    /// active path treats the row as gone. Archive doesn't delete the
    /// row, but `find` filters by status when called from `session`
    /// only if the repo returns nil; here `find` still returns the
    /// archived row, so we instead check that the handle cache was
    /// cleared.
    func testArchiveClearsHandleCache() {
        let sid = UUID().uuidString
        repo.save(makeRecord(sid: sid, title: "Has cached handle", status: .created))
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)

        // Allocate the handle so it's in the cache.
        let handle = manager.session(sid)
        XCTAssertNotNil(handle)
        XCTAssertNotNil(manager.existingSession(sid))

        manager.archive(sid)

        XCTAssertNil(manager.existingSession(sid), "Archive must drop the cached handle")
    }

    /// Unarchive defensively clears any stale cached handle so the next
    /// view-mount allocates a fresh one against the now-flipped row.
    /// Belt-and-braces — `archive` already cleared it, but if a caller
    /// somehow reseeded the cache between archive and unarchive (e.g.
    /// `session(sid)` on an archived row would currently still return
    /// a handle from the InMemory mock since it doesn't filter), the
    /// duplicate clear stays correct.
    func testUnarchiveClearsHandleCache() {
        let sid = UUID().uuidString
        repo.save(makeRecord(sid: sid, title: "Archived row", status: .archived, archivedAt: Date()))
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)

        // Force-allocate a handle against the archived row (the InMemory
        // mock's `find` still resolves archived rows, so `session(_:)`
        // returns a handle even though production sidebar wouldn't show
        // the row). Verifies unarchive is defensive.
        _ = manager.session(sid)
        XCTAssertNotNil(manager.existingSession(sid))

        manager.unarchive(sid)

        XCTAssertNil(manager.existingSession(sid), "Unarchive must drop any stale cached handle")
    }

    // MARK: - Archived folder options (derived state)

    /// `archivedFolderOptions` is derived in lock-step with
    /// `archivedRecords` on every refresh path. After
    /// `refreshArchivedRecords()`, the list must reflect the distinct
    /// `originPath` values of all archived rows, sorted alphabetically
    /// by leaf name, with nil/empty paths silently dropped.
    func testArchivedFolderOptionsDerivedFromSyncRefresh() {
        repo.save(
            makeRecord(
                sid: "a", title: "A1",
                cwd: "/Users/me/work/project-a", originPath: "/Users/me/work/project-a",
                status: .archived, archivedAt: Date()))
        repo.save(
            makeRecord(
                sid: "b", title: "B1",
                cwd: "/Users/me/work/project-b", originPath: "/Users/me/work/project-b",
                status: .archived, archivedAt: Date()))
        // Second row at project-a — should not produce a duplicate folder.
        repo.save(
            makeRecord(
                sid: "a2", title: "A2",
                cwd: "/Users/me/work/project-a", originPath: "/Users/me/work/project-a",
                status: .archived, archivedAt: Date()))
        // Row with nil originPath — should be silently dropped from options.
        repo.save(
            makeRecord(
                sid: "orphan", title: "No origin",
                cwd: "/somewhere", originPath: nil,
                status: .archived, archivedAt: Date()))
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)

        manager.refreshArchivedRecords()

        XCTAssertEqual(
            manager.archivedFolderOptions.map(\.path),
            ["/Users/me/work/project-a", "/Users/me/work/project-b"],
            "Distinct originPath buckets, sorted alphabetically by leaf name"
        )
        XCTAssertEqual(
            manager.archivedFolderOptions.map(\.name),
            ["project-a", "project-b"]
        )
    }

    /// `refreshArchivedRecordsAsync()` must also refresh the derived
    /// folder options — the Archive page's first paint goes through this
    /// path and the popover would otherwise see a stale empty list.
    func testArchivedFolderOptionsDerivedFromAsyncRefresh() async {
        repo.save(
            makeRecord(
                sid: "a", title: "Async A",
                cwd: "/Users/me/projects/alpha", originPath: "/Users/me/projects/alpha",
                status: .archived, archivedAt: Date()))
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)

        await manager.refreshArchivedRecordsAsync()

        XCTAssertEqual(manager.archivedFolderOptions.map(\.path), ["/Users/me/projects/alpha"])
        XCTAssertEqual(manager.archivedFolderOptions.first?.name, "alpha")
    }

    /// Archiving a session updates `archivedFolderOptions` in the same
    /// transaction as `archivedRecords`, so an Archive page open at the
    /// moment of archive sees both lists move together.
    func testArchivingSessionAddsToFolderOptions() {
        let sid = UUID().uuidString
        repo.save(
            makeRecord(
                sid: sid, title: "About to archive",
                cwd: "/Users/me/repos/foo", originPath: "/Users/me/repos/foo",
                status: .created))
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)
        XCTAssertEqual(manager.archivedFolderOptions.count, 0)

        manager.archive(sid)

        XCTAssertEqual(manager.archivedFolderOptions.map(\.path), ["/Users/me/repos/foo"])
        XCTAssertEqual(manager.archivedFolderOptions.first?.name, "foo")
    }

    /// Unarchiving the last session in a folder removes that folder from
    /// the picker options, so a stale-selection cleanup in the Archive
    /// page has something concrete to compare against.
    func testUnarchivingLastSessionInFolderRemovesItFromOptions() {
        let sid = UUID().uuidString
        repo.save(
            makeRecord(
                sid: sid, title: "Only one in folder",
                cwd: "/Users/me/repos/bar", originPath: "/Users/me/repos/bar",
                status: .archived, archivedAt: Date()))
        let manager = SessionManager(
            repository: repo, worktreeArchive: noopSideEffect, worktreeRestore: noopSideEffect)
        manager.refreshArchivedRecords()
        XCTAssertEqual(manager.archivedFolderOptions.count, 1)

        manager.unarchive(sid)

        XCTAssertEqual(manager.archivedFolderOptions.count, 0)
    }

    // MARK: - Worktree side-effect routing

    /// A non-worktree archive does NOT call the worktree side-effect
    /// closure (so we never shell out to git on a plain folder
    /// session).
    func testArchiveSkipsWorktreeSideEffectForNonWorktreeSession() {
        let sid = UUID().uuidString
        repo.save(makeRecord(sid: sid, title: "Plain folder", status: .created, isWorktree: false))
        let recorder = SideEffectRecorder()
        let manager = SessionManager(
            repository: repo,
            worktreeArchive: recorder.record,
            worktreeRestore: noopSideEffect
        )

        manager.archive(sid)

        XCTAssertEqual(recorder.calls.count, 0, "Plain-folder session must not trigger worktree teardown")
    }

    /// A worktree archive fires the side-effect closure with the
    /// archived record (carrying cwd / originPath / worktreeBranch so
    /// the closure can call `Worktree.remove` against the on-disk
    /// state).
    func testArchiveFiresWorktreeSideEffectForWorktreeSession() {
        let sid = UUID().uuidString
        repo.save(
            makeRecord(
                sid: sid,
                title: "Worktree session",
                cwd: "/repo/.claude/worktrees/eager-curie-abcdef",
                originPath: "/repo",
                status: .created,
                isWorktree: true,
                worktreeBranch: "eager-curie-abcdef"
            ))
        let recorder = SideEffectRecorder()
        let manager = SessionManager(
            repository: repo,
            worktreeArchive: recorder.record,
            worktreeRestore: noopSideEffect
        )

        manager.archive(sid)

        XCTAssertEqual(recorder.calls.count, 1, "Worktree archive must call worktreeArchive once")
        XCTAssertEqual(recorder.calls.first?.sessionId, sid)
        XCTAssertEqual(recorder.calls.first?.cwd, "/repo/.claude/worktrees/eager-curie-abcdef")
        XCTAssertEqual(recorder.calls.first?.originPath, "/repo")
        XCTAssertEqual(recorder.calls.first?.worktreeBranch, "eager-curie-abcdef")
        XCTAssertTrue(recorder.calls.first?.isWorktree ?? false)
    }

    /// Unarchiving a non-worktree session does NOT call the restore
    /// closure.
    func testUnarchiveSkipsWorktreeSideEffectForNonWorktreeSession() {
        let sid = UUID().uuidString
        repo.save(
            makeRecord(
                sid: sid,
                title: "Plain folder",
                status: .archived,
                archivedAt: Date(),
                isWorktree: false
            ))
        let recorder = SideEffectRecorder()
        let manager = SessionManager(
            repository: repo,
            worktreeArchive: noopSideEffect,
            worktreeRestore: recorder.record
        )

        manager.unarchive(sid)

        XCTAssertEqual(recorder.calls.count, 0)
    }

    /// Unarchiving a worktree session fires the restore closure with
    /// the record so the closure can call `Worktree.restore` to rebuild
    /// the on-disk worktree directory git removed during archive.
    func testUnarchiveFiresWorktreeSideEffectForWorktreeSession() {
        let sid = UUID().uuidString
        repo.save(
            makeRecord(
                sid: sid,
                title: "Worktree session",
                cwd: "/repo/.claude/worktrees/jolly-pare-d40302",
                originPath: "/repo",
                status: .archived,
                archivedAt: Date(),
                isWorktree: true,
                worktreeBranch: "jolly-pare-d40302"
            ))
        let recorder = SideEffectRecorder()
        let manager = SessionManager(
            repository: repo,
            worktreeArchive: noopSideEffect,
            worktreeRestore: recorder.record
        )

        manager.unarchive(sid)

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.sessionId, sid)
        XCTAssertEqual(recorder.calls.first?.cwd, "/repo/.claude/worktrees/jolly-pare-d40302")
        XCTAssertEqual(recorder.calls.first?.originPath, "/repo")
        XCTAssertEqual(recorder.calls.first?.worktreeBranch, "jolly-pare-d40302")
    }

    /// The worktree side-effect closure is invoked AFTER the DB has
    /// already flipped status: querying the repo from inside the
    /// closure must see the archived row, not the pre-archive row.
    /// Captures the contract that `defaultWorktreeArchive` relies on —
    /// the closure is allowed to fire on a background queue and the DB
    /// state it inspects must be the post-archive state.
    func testWorktreeSideEffectFiresAfterDBFlip() {
        let sid = UUID().uuidString
        repo.save(
            makeRecord(
                sid: sid,
                title: "Worktree session",
                cwd: "/repo/.claude/worktrees/wt",
                originPath: "/repo",
                status: .created,
                isWorktree: true,
                worktreeBranch: "wt"
            ))

        // Capture the repo's view of the row at the moment the side
        // effect runs. The closure runs synchronously on the main actor
        // under the test injection, so direct reads are safe.
        let probe = StatusProbe(repo: repo, sessionId: sid)
        let manager = SessionManager(
            repository: repo,
            worktreeArchive: probe.capture,
            worktreeRestore: noopSideEffect
        )

        manager.archive(sid)

        XCTAssertEqual(probe.observedStatus, .archived, "DB flip must precede the worktree side effect")
    }

    /// Default-construct a `SessionRecord` for the in-memory repo.
    private func makeRecord(
        sid: String,
        title: String,
        cwd: String? = nil,
        originPath: String? = nil,
        status: SessionStatus,
        archivedAt: Date? = nil,
        lastActiveAt: Date = Date(),
        isWorktree: Bool = false,
        worktreeBranch: String? = nil
    ) -> SessionRecord {
        SessionRecord(
            sessionId: sid,
            title: title,
            cwd: cwd,
            isWorktree: isWorktree,
            originPath: originPath,
            createdAt: lastActiveAt,
            lastActiveAt: lastActiveAt,
            status: status,
            archivedAt: archivedAt,
            worktreeBranch: worktreeBranch
        )
    }

    /// Sink that records every invocation for later inspection.
    private final class SideEffectRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [SessionRecord] = []

        func record(_ record: SessionRecord) {
            lock.lock()
            calls.append(record)
            lock.unlock()
        }
    }

    /// Reads the post-archive repo status at the moment the worktree
    /// side-effect fires. Used by `testWorktreeSideEffectFiresAfterDBFlip`
    /// to assert the DB mutation happens before the closure runs.
    private final class StatusProbe: @unchecked Sendable {
        private let repo: any SessionRepository
        private let sessionId: String
        private(set) var observedStatus: SessionStatus?

        init(repo: any SessionRepository, sessionId: String) {
            self.repo = repo
            self.sessionId = sessionId
        }

        func capture(_ record: SessionRecord) {
            observedStatus = repo.find(sessionId)?.status
        }
    }

    /// Discard the side effect — for tests that exercise the DB path
    /// without caring whether worktree teardown was invoked.
    private let noopSideEffect: SessionManager.WorktreeSideEffect = { _ in }
}

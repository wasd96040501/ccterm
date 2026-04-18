import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2.init(sessionId:repository:)` hydrate behavior —
/// config fields are read synchronously from the repository (if any record
/// exists). No db write, no history load, `status = .notStarted`.
@MainActor
final class SessionHandle2InitTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo() -> SessionRepository {
        SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
    }

    // MARK: - No record: all defaults, no db write

    func testInit_noRecord_keepsDefaults() {
        let repo = makeRepo()
        let handle = SessionHandle2(sessionId: "fresh", repository: repo)

        XCTAssertEqual(handle.title, "")
        XCTAssertNil(handle.cwd)
        XCTAssertFalse(handle.isWorktree)
        XCTAssertNil(handle.originPath)
        XCTAssertNil(handle.worktreeBranch)
        XCTAssertFalse(handle.isGeneratingBranch)
        XCTAssertNil(handle.termination)
        XCTAssertNil(handle.model)
        XCTAssertNil(handle.effort)
        XCTAssertEqual(handle.permissionMode, .default)
        XCTAssertTrue(handle.additionalDirectories.isEmpty)
        XCTAssertTrue(handle.pluginDirectories.isEmpty)
        XCTAssertTrue(handle.messages.isEmpty)

        guard case .notStarted = handle.status else {
            return XCTFail("expected .notStarted, got \(handle.status)")
        }
        guard case .notLoaded = handle.historyLoadState else {
            return XCTFail("expected .notLoaded, got \(handle.historyLoadState)")
        }
    }

    func testInit_noRecord_doesNotWriteDB() {
        let repo = makeRepo()
        _ = SessionHandle2(sessionId: "ghost", repository: repo)

        XCTAssertNil(repo.find("ghost"), "init must not create an orphan record")
    }

    // MARK: - With record: all fields hydrated

    func testInit_hydratesAllFields() {
        let repo = makeRepo()
        let extra = SessionExtra(
            pluginDirs: ["/plug/a", "/plug/b"],
            permissionMode: ccterm.PermissionMode.acceptEdits.rawValue,
            addDirs: ["/extra/one"],
            model: "claude-opus-4-7",
            effort: Effort.high.rawValue
        )
        repo.save(SessionRecord(
            sessionId: "hydrated",
            title: "my chat",
            cwd: "/work/repo",
            isWorktree: true,
            originPath: "/origin/repo",
            extra: extra,
            error: "boot failed: exit 137",
            worktreeBranch: "feature/x"
        ))

        let handle = SessionHandle2(sessionId: "hydrated", repository: repo)

        XCTAssertEqual(handle.title, "my chat")
        XCTAssertEqual(handle.cwd, "/work/repo")
        XCTAssertTrue(handle.isWorktree)
        XCTAssertEqual(handle.originPath, "/origin/repo")
        XCTAssertEqual(handle.worktreeBranch, "feature/x")
        XCTAssertEqual(handle.termination, "boot failed: exit 137")
        XCTAssertEqual(handle.model, "claude-opus-4-7")
        XCTAssertEqual(handle.effort, .high)
        XCTAssertEqual(handle.permissionMode, .acceptEdits)
        XCTAssertEqual(handle.additionalDirectories, ["/extra/one"])
        XCTAssertEqual(handle.pluginDirectories, ["/plug/a", "/plug/b"])
    }

    func testInit_partialRecord_unsetFieldsStayDefault() {
        let repo = makeRepo()
        repo.save(SessionRecord(
            sessionId: "partial",
            cwd: "/only/cwd",
            extra: SessionExtra(permissionMode: ccterm.PermissionMode.plan.rawValue)
        ))

        let handle = SessionHandle2(sessionId: "partial", repository: repo)

        XCTAssertEqual(handle.cwd, "/only/cwd")
        XCTAssertEqual(handle.permissionMode, .plan)
        XCTAssertNil(handle.model)
        XCTAssertNil(handle.effort)
        XCTAssertNil(handle.originPath)
        XCTAssertNil(handle.worktreeBranch)
        XCTAssertNil(handle.termination)
        XCTAssertTrue(handle.additionalDirectories.isEmpty)
        XCTAssertTrue(handle.pluginDirectories.isEmpty)
    }

    func testInit_unrecognizedPermissionMode_keepsDefault() {
        let repo = makeRepo()
        repo.save(SessionRecord(
            sessionId: "bad-mode",
            extra: SessionExtra(permissionMode: "totally-made-up")
        ))

        let handle = SessionHandle2(sessionId: "bad-mode", repository: repo)
        XCTAssertEqual(handle.permissionMode, .default)
    }

    func testInit_unrecognizedEffort_keepsNil() {
        let repo = makeRepo()
        repo.save(SessionRecord(
            sessionId: "bad-effort",
            extra: SessionExtra(effort: "ultra")
        ))

        let handle = SessionHandle2(sessionId: "bad-effort", repository: repo)
        XCTAssertNil(handle.effort)
    }

    // MARK: - init does not load history

    func testInit_doesNotLoadHistory() {
        let repo = makeRepo()
        repo.save(SessionRecord(sessionId: "with-history", cwd: "/x"))

        let handle = SessionHandle2(sessionId: "with-history", repository: repo)

        XCTAssertTrue(handle.messages.isEmpty)
        guard case .notLoaded = handle.historyLoadState else {
            return XCTFail("init must leave history .notLoaded, got \(handle.historyLoadState)")
        }
    }
}

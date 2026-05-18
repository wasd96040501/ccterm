import AgentSDK
import XCTest

@testable import ccterm

/// Confirms `SessionDraft` is a pure value carrier: setters mutate
/// `config` / presence flags only, with **no** repository writes and no
/// RPCs (there is no CLI yet). The first DB write happens at promotion
/// time inside `SessionRuntime.fromDraft`, not on a `set*` call here.
@MainActor
final class SessionDraftTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Construct + read defaults. A fresh draft has empty `config`,
    /// empty `title`, no record persisted.
    func testFreshDraftStartsEmpty() {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        let draft = SessionDraft(sessionId: sid, repository: repo)

        XCTAssertEqual(draft.sessionId, sid)
        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.config, SessionConfig())
        XCTAssertFalse(draft.isFocused)
        XCTAssertFalse(draft.hasUnread)
        XCTAssertNil(repo.find(sid), "draft init must not persist a record")
    }

    /// `setCwd` / `setWorktree` / `setOriginPath` / `setSourceBranch` /
    /// `setWorktreeBranch` / `setPluginDirectories` write to `config`
    /// directly and do NOT touch the repository — even if the same
    /// sessionId already has a record in the repo (defensive — the
    /// production flow keeps draft and record disjoint, but the
    /// invariant is "no DB write from a setter," full stop).
    func testDraftSettersWriteConfigOnlyNotRepository() {
        let repo = InMemorySessionRepository()
        // Pre-seed a record to prove draft setters are inert against it.
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid,
                title: "preexisting",
                cwd: "/old/cwd",
                isWorktree: false,
                originPath: "/old/origin",
                status: .pending,
                worktreeBranch: nil
            ))

        let draft = SessionDraft(sessionId: sid, repository: repo)
        draft.setCwd("/new/cwd")
        draft.setWorktree(true)
        draft.setOriginPath("/new/origin")
        draft.setSourceBranch("feature/x")
        draft.setWorktreeBranch("worktree-foo")
        draft.setPluginDirectories(["/plug/a"])
        draft.setModel("default")
        draft.setEffort(.high)
        draft.setPermissionMode(.acceptEdits)
        draft.setFastMode(true)
        draft.setAdditionalDirectories(["/extra"])

        XCTAssertEqual(draft.cwd, "/new/cwd")
        XCTAssertEqual(draft.isWorktree, true)
        XCTAssertEqual(draft.originPath, "/new/origin")
        XCTAssertEqual(draft.sourceBranch, "feature/x")
        XCTAssertEqual(draft.worktreeBranch, "worktree-foo")
        XCTAssertEqual(draft.pluginDirectories, ["/plug/a"])
        XCTAssertEqual(draft.model, "default")
        XCTAssertEqual(draft.effort, .high)
        XCTAssertEqual(draft.permissionMode, .acceptEdits)
        XCTAssertEqual(draft.fastModeEnabled, true)
        XCTAssertEqual(draft.additionalDirectories, ["/extra"])

        // Repository is untouched — its pre-seeded values survive
        // every draft setter.
        let snapshot = repo.find(sid)
        XCTAssertEqual(snapshot?.cwd, "/old/cwd")
        XCTAssertEqual(snapshot?.isWorktree, false)
        XCTAssertEqual(snapshot?.originPath, "/old/origin")
        XCTAssertEqual(snapshot?.title, "preexisting")
    }

    /// Focusing the draft clears `hasUnread`; defocusing does not.
    /// Mirrors the runtime's `setFocused` contract so the sidebar
    /// indicator works the same in both phases.
    func testSetFocusedClearsUnread() {
        let draft = SessionDraft(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        draft.hasUnread = true

        draft.setFocused(true)
        XCTAssertTrue(draft.isFocused)
        XCTAssertFalse(draft.hasUnread)

        draft.hasUnread = true
        draft.setFocused(false)
        XCTAssertFalse(draft.isFocused)
        XCTAssertTrue(draft.hasUnread, "defocus must NOT clear hasUnread")
    }
}

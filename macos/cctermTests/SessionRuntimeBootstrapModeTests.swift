import AgentSDK
import XCTest

@testable import ccterm

/// Covers `SessionRuntime.shouldResumeBootstrap(for:)` and the closely-tied
/// `makeAgentConfig()` wiring that decides whether the next CLI launch
/// uses `--session-id` (fresh) or `--resume` (resume).
///
/// Regression target: a fresh worktree session goes through an eager
/// `repository.save` BEFORE the worktree is provisioned so the sidebar
/// can show a row immediately. That save lands a row with status =
/// `.pending`. After the worktree-creation Task succeeds, the continuation
/// runs the rest of `ensureStarted`. A prior version of that continuation
/// inadvertently flipped the bootstrap mode to "resume" — the CLI then
/// died on first launch with:
///
///     process exited (code 1): No conversation found with session ID: …
///
/// The pure rule below pins down "resume iff durable status == .created",
/// and the integration-shaped `makeAgentConfig` assertions confirm the
/// rule is what actually drives the SDK config that bootstrap hands to
/// AgentSDK.
@MainActor
final class SessionRuntimeBootstrapModeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Pure rule

    /// No durable record → there is no CLI JSONL to resume from. Must use
    /// fresh mode.
    func testNoRecordIsFreshMode() {
        XCTAssertFalse(SessionRuntime.shouldResumeBootstrap(for: nil))
    }

    /// Reproduces the worktree-fresh-session state at the exact moment the
    /// bug used to fire: the eager save has run (so a row exists with
    /// status `.pending`) and `Worktree.create` has just returned success,
    /// but the CLI has never been launched. `shouldResumeBootstrap` MUST
    /// return false here — anything else triggers `--resume` against a
    /// non-existent conversation and the CLI exits 1.
    func testPendingRecordFromWorktreeEagerSaveIsFreshMode() {
        let record = SessionRecord(
            sessionId: UUID().uuidString,
            title: "",
            cwd: "/tmp/fake-worktree",
            isWorktree: true,
            originPath: "/tmp/fake-origin",
            status: .pending,
            worktreeBranch: "adoring-benz-b7353f"
        )
        XCTAssertFalse(
            SessionRuntime.shouldResumeBootstrap(for: record),
            "pending records have no CLI JSONL — must launch fresh, never resume")
    }

    /// The only state that should produce resume mode: a record whose
    /// previous bootstrap completed `session.start()` and was marked
    /// `.created`.
    func testCreatedRecordIsResumeMode() {
        let record = SessionRecord(
            sessionId: UUID().uuidString,
            title: "Some session",
            cwd: "/tmp/some-cwd",
            status: .created
        )
        XCTAssertTrue(
            SessionRuntime.shouldResumeBootstrap(for: record),
            "created records have a CLI JSONL — must resume, not start fresh")
    }

    /// Archived sessions follow the same "no JSONL guarantee" rule as
    /// pending — they don't get re-launched in normal flow, but if they
    /// somehow did, fresh mode is the safe default.
    func testArchivedRecordIsFreshMode() {
        let record = SessionRecord(
            sessionId: UUID().uuidString,
            status: .archived
        )
        XCTAssertFalse(SessionRuntime.shouldResumeBootstrap(for: record))
    }

    // MARK: - Wired into makeAgentConfig

    /// No persisted record yet → SDK config uses `sessionId`, not `resume`.
    /// This is the path a brand-new non-worktree session walks the first
    /// time through bootstrap.
    func testMakeAgentConfigFreshWhenNoRecord() {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        // `setCwd` lives exclusively on `SessionDraft` now — tests poke
        // `config` directly to simulate the post-promotion state where
        // the runtime has already received a draft's cwd.
        runtime.config.cwd = "/tmp/fresh"

        let config = runtime.makeAgentConfig(customCommand: nil)

        XCTAssertEqual(
            config.sessionId, runtime.sessionId,
            "fresh launches set --session-id to the runtime's session id")
        XCTAssertNil(
            config.resume,
            "fresh launches must not set --resume")
    }

    /// Bug-trigger state in production:
    ///
    /// 1. Eager-save writes a `.pending` row before `Worktree.create` runs.
    /// 2. Worktree provisioning finishes; the continuation hands control
    ///    back to `ensureStarted`.
    /// 3. `makeAgentConfig` is consulted to build the SDK config.
    ///
    /// `makeAgentConfig` MUST see the `.pending` record and produce a
    /// fresh-launch config. The previous bug switched to resume mode here
    /// and the CLI rejected the launch with "No conversation found …".
    func testMakeAgentConfigFreshWhenPendingRecordExists() {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        // Simulate `ensureStarted`'s eager save: the worktree-fresh
        // pre-provision row, status .pending.
        repo.save(
            SessionRecord(
                sessionId: sid,
                title: "",
                cwd: "/tmp/fake-worktree",
                isWorktree: true,
                originPath: "/tmp/fake-origin",
                status: .pending,
                worktreeBranch: "adoring-benz-b7353f"
            ))
        let runtime = SessionRuntime(sessionId: sid, repository: repo)

        let config = runtime.makeAgentConfig(customCommand: nil)

        XCTAssertEqual(
            config.sessionId, sid,
            "post-worktree-provision launch must use --session-id, not --resume")
        XCTAssertNil(
            config.resume,
            "post-worktree-provision launch must NOT pass --resume — the "
                + "CLI conversation doesn't exist yet")
    }

    /// Resume path: existing record with `.created` status (CLI launched
    /// at least once) → SDK config swaps to `resume`.
    func testMakeAgentConfigResumesWhenRecordIsCreated() {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid,
                title: "Existing",
                cwd: "/tmp/existing",
                status: .created
            ))
        let runtime = SessionRuntime(sessionId: sid, repository: repo)

        let config = runtime.makeAgentConfig(customCommand: nil)

        XCTAssertNil(
            config.sessionId,
            "resume mode must clear --session-id")
        XCTAssertEqual(
            config.resume, sid,
            "resume mode must pass --resume <session-id>")
    }
}

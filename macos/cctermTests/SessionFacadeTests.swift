import AgentSDK
import XCTest

@testable import ccterm

/// Covers `Session`'s phase-aware forwarding contract — the read
/// surface that UI bindings depend on must match the underlying phase
/// (draft vs runtime) without UI ever inspecting `phase` directly.
@MainActor
final class SessionFacadeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Phase initialization

    /// A `Session` built from an existing record starts in `.active`
    /// with `runtime` non-nil. `hasRecord` is true.
    func testRecordInitStartsInActivePhase() {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        let record = SessionRecord(
            sessionId: sid,
            title: "Hello",
            cwd: "/tmp/from-record",
            status: .created
        )
        repo.save(record)

        let session = ccterm.Session(
            record: record,
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() }
        )

        XCTAssertTrue(session.hasRecord)
        XCTAssertNotNil(session.runtime)
        XCTAssertNil(session.draft)
        XCTAssertEqual(session.title, "Hello")
        XCTAssertEqual(session.cwd, "/tmp/from-record")
    }

    /// A `Session` built from a fresh draftSessionId starts in `.draft`
    /// with `draft` non-nil. `hasRecord` is false.
    func testDraftInitStartsInDraftPhase() {
        let sid = UUID().uuidString
        let session = ccterm.Session(
            draftSessionId: sid,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )

        XCTAssertFalse(session.hasRecord)
        XCTAssertNotNil(session.draft)
        XCTAssertNil(session.runtime)
        XCTAssertEqual(session.status, .notStarted)
        XCTAssertEqual(session.historyLoadState, .notLoaded)
        XCTAssertEqual(session.messages.count, 0)
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - Forwarding reads

    /// Draft-phase reads come from the underlying `SessionDraft` — its
    /// `config` mutations flow through to `session.cwd` / `.model` /
    /// `.permissionMode` etc.
    func testDraftReadsForwardConfig() {
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        guard let draft = session.draft else { return XCTFail("expected draft phase") }

        draft.setCwd("/tmp/x")
        draft.setWorktree(true)
        draft.setModel("default")
        draft.setEffort(.high)
        draft.setPermissionMode(.acceptEdits)
        draft.setFastMode(true)
        draft.setAdditionalDirectories(["/extra"])

        XCTAssertEqual(session.cwd, "/tmp/x")
        XCTAssertEqual(session.isWorktree, true)
        XCTAssertEqual(session.model, "default")
        XCTAssertEqual(session.effort, .high)
        XCTAssertEqual(session.permissionMode, .acceptEdits)
        XCTAssertEqual(session.fastModeEnabled, true)
        XCTAssertEqual(session.additionalDirectories, ["/extra"])
    }

    /// Active-phase reads come from the underlying runtime's `config`.
    func testActiveReadsForwardRuntimeConfig() {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid,
                title: "T",
                cwd: "/tmp/active",
                status: .created
            ))
        let session = ccterm.Session(
            record: repo.find(sid)!,
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() }
        )
        guard let runtime = session.runtime else { return XCTFail("expected active") }

        runtime.setModel("haiku")
        runtime.setPermissionMode(.acceptEdits)

        XCTAssertEqual(session.model, "haiku")
        XCTAssertEqual(session.permissionMode, .acceptEdits)
        XCTAssertEqual(session.cwd, "/tmp/active")
    }

    // MARK: - Phase-aware write forwarding

    /// `session.setModel(...)` in `.draft` mutates the draft (no RPC);
    /// in `.active` it mutates the runtime AND fires the CLI RPC.
    func testSetterRoutesToCorrectPhase() async {
        // Draft phase: writes draft, never reaches CLI.
        let fake = FakeCLIClient()
        let draftSession = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        draftSession.setModel("default")
        draftSession.setPermissionMode(.acceptEdits)
        XCTAssertEqual(draftSession.draft?.model, "default")
        XCTAssertEqual(draftSession.draft?.permissionMode, .acceptEdits)
        XCTAssertTrue(fake.modelCalls.isEmpty, "draft setter must not RPC")

        // Active phase: writes runtime, no RPC yet (CLI not attached).
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(SessionRecord(sessionId: sid, status: .created))
        let activeSession = ccterm.Session(
            record: repo.find(sid)!,
            repository: repo,
            cliClientFactory: { _ in fake }
        )
        activeSession.setModel("sonnet")
        XCTAssertEqual(activeSession.runtime?.model, "sonnet")
        XCTAssertTrue(fake.modelCalls.isEmpty, "detached runtime setter doesn't RPC either")
    }
}

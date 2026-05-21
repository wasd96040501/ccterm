import AgentSDK
import XCTest

@testable import ccterm

/// Covers `SessionRuntime.receive(_:)`'s `.system(.status)` branch:
/// CLI broadcasts the authoritative `permissionMode` after the
/// `toolPermissionContext.mode` changes server-side. The handle must
/// adopt that value into its observable + persist it to the record.
///
/// Regression target: prior to this branch existing, `receive`'s
/// `default: break` silently dropped every `system.status` push. Result:
///
/// - User clicks "Allow always" on an Edit permission card. The CLI's
///   `permission_suggestions` carries `setMode → acceptEdits`. The CLI
///   applies it and pushes `system.status { permissionMode:'acceptEdits' }`.
///   ccterm's local `permissionMode` stays at `.default` — the mode
///   picker, status pill, and any `.task(id: permissionMode)` watchers
///   diverge from CLI truth.
/// - Claude calls EnterPlanMode (no permission_request — the tool is
///   on the CLI's allowlist). The CLI flips its mode to `plan` and
///   pushes `system.status`. Without this branch, the UI never learns
///   plan mode is active.
/// - User sets `bypassPermissions` via the picker. CLI rejects (no
///   `--allow-dangerously-skip-permissions`) and pushes `default`.
///   With this branch the optimistic local write is self-healed back
///   to `default` instead of staying as a stale `bypassPermissions`.
@MainActor
final class SessionRuntimeReceiveStatusTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Happy path: `permissionMode=acceptEdits` arrives → observable is
    /// updated and the repository extra is written.
    func testReceiveStatusUpdatesObservableAndDB() {
        let sid = UUID().uuidString
        let repo = InMemorySessionRepository()
        repo.save(SessionRecord(sessionId: sid, title: "", cwd: "/tmp", status: .created))
        let runtime = SessionRuntime(sessionId: sid, repository: repo)
        XCTAssertEqual(runtime.permissionMode, .default)

        runtime.receive(
            Message2Fixtures.systemStatus(permissionMode: "acceptEdits", sessionId: sid))

        XCTAssertEqual(runtime.permissionMode, .acceptEdits)
        XCTAssertEqual(repo.find(sid)?.extra.permissionMode, "acceptEdits")
    }

    /// Pre-persistence (no record in repo, e.g. before the first
    /// bootstrap eager-save lands): observable still updates so the UI
    /// stays correct, but the DB write is skipped (there's nothing to
    /// update).
    func testReceiveStatusUpdatesObservableEvenBeforePersistence() {
        let sid = UUID().uuidString
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(sessionId: sid, repository: repo)

        runtime.receive(
            Message2Fixtures.systemStatus(permissionMode: "plan", sessionId: sid))

        XCTAssertEqual(runtime.permissionMode, .plan)
        XCTAssertNil(repo.find(sid))  // no eager record, no DB write attempted
    }

    /// Idempotency: a `system.status` carrying the same mode the handle
    /// already holds is a no-op. We assert via the DB — the record's
    /// `lastActiveAt` would shift if `updateExtra` ran. Today the
    /// repository touches the extra dict only; we read `permissionMode`
    /// before and after and confirm the same recorded value (which is
    /// nil here, since adopt is gated on a real change).
    func testSameModeIsNoOp() {
        let sid = UUID().uuidString
        let repo = InMemorySessionRepository()
        repo.save(SessionRecord(sessionId: sid, title: "", cwd: "/tmp", status: .created))
        let runtime = SessionRuntime(sessionId: sid, repository: repo)
        XCTAssertEqual(runtime.permissionMode, .default)
        XCTAssertNil(repo.find(sid)?.extra.permissionMode)

        // Same mode CLI already knows: no write.
        runtime.receive(
            Message2Fixtures.systemStatus(permissionMode: "default", sessionId: sid))

        XCTAssertEqual(runtime.permissionMode, .default)
        XCTAssertNil(
            repo.find(sid)?.extra.permissionMode,
            "DB extra must remain unset — adopt should skip the write when mode didn't change")
    }

    /// Unknown mode strings (forward compat / corrupted CLI payload):
    /// don't crash, don't half-apply, keep the previous mode.
    func testUnknownModeIsIgnored() {
        let sid = UUID().uuidString
        let repo = InMemorySessionRepository()
        repo.save(SessionRecord(sessionId: sid, title: "", cwd: "/tmp", status: .created))
        let runtime = SessionRuntime(sessionId: sid, repository: repo)

        runtime.receive(
            Message2Fixtures.systemStatus(permissionMode: "warp_drive_engaged", sessionId: sid))

        XCTAssertEqual(runtime.permissionMode, .default)
        XCTAssertNil(repo.find(sid)?.extra.permissionMode)
    }

    /// Self-heal: the user optimistically flips to `bypassPermissions`
    /// via `setPermissionMode` (which writes the observable
    /// immediately so the UI doesn't lag the click). The CLI rejects
    /// it and broadcasts `system.status` with the actual mode
    /// (`default`). `receive` must pull the observable back to truth
    /// — without this, UI shows `bypass` while CLI is in `default`,
    /// indefinitely.
    func testReceivedStatusOverridesOptimisticLocalWrite() {
        let sid = UUID().uuidString
        let repo = InMemorySessionRepository()
        repo.save(SessionRecord(sessionId: sid, title: "", cwd: "/tmp", status: .created))
        let runtime = SessionRuntime(sessionId: sid, repository: repo)

        // Step 1: user toggle. Optimistic write lands.
        runtime.setPermissionMode(.bypassPermissions)
        XCTAssertEqual(runtime.permissionMode, .bypassPermissions)

        // Step 2: CLI rejects, broadcasts the corrected mode.
        runtime.receive(
            Message2Fixtures.systemStatus(permissionMode: "default", sessionId: sid))

        XCTAssertEqual(
            runtime.permissionMode, .default,
            "CLI's system.status must override the rejected optimistic local write")
        XCTAssertEqual(repo.find(sid)?.extra.permissionMode, "default")
    }

    /// EnterPlanMode flow: CLI flips to `plan` without ever sending a
    /// permission_request (the tool is on its allowlist). The only
    /// signal ccterm gets is `system.status`.
    func testEnterPlanModeBroadcastIsAdopted() {
        let sid = UUID().uuidString
        let repo = InMemorySessionRepository()
        repo.save(SessionRecord(sessionId: sid, title: "", cwd: "/tmp", status: .created))
        let runtime = SessionRuntime(sessionId: sid, repository: repo)

        runtime.receive(
            Message2Fixtures.systemStatus(permissionMode: "plan", sessionId: sid))

        XCTAssertEqual(runtime.permissionMode, .plan)
        XCTAssertEqual(repo.find(sid)?.extra.permissionMode, "plan")
    }
}

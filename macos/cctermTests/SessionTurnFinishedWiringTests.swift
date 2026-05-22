import AgentSDK
import XCTest

@testable import ccterm

/// Verifies the runtime → Session → bridge → controller wire-up for the
/// "turn finished" signal. When the CLI sends `.result`,
/// `SessionRuntime` fires `onTurnFinishedLive`, which
/// `Session.wireRuntimeMessagesSink` connects to
/// `Transcript2EntryBridge.handleTurnFinished()` →
/// `Transcript2Controller.clearAllRunningStatuses()`. Net effect: any
/// tool surface that was still `.running` at turn close flips to
/// `.completed` without the renderer needing to know about turn events.
@MainActor
final class SessionTurnFinishedWiringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Drive the full path: receive an assistant tool_use, observe
    /// `.running` on the controller, then receive `.result` and observe
    /// the auto-clear.
    func testResultMessageClearsRunningToolsViaSessionWiring() {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository()
        )
        let session = ccterm.Session(runtime: runtime)

        // Feed a live assistant tool_use through the runtime — the
        // session's wired sink translates it into bridge `.appended`
        // and the bridge pushes `.running` to the controller.
        let toolUseId = "tu-e2e"
        runtime.receive(
            Message2Fixtures.assistantRead(
                toolUseId: toolUseId, filePath: "/tmp/x.txt"))
        let childId = StableBlockID.derive("tool", toolUseId)
        XCTAssertEqual(
            session.controller.toolStatus(for: childId),
            .running,
            "live assistant tool_use without result should be .running")

        // Turn ends. Runtime fires `onTurnFinishedLive` synchronously,
        // bridge clears running.
        runtime.receive(Message2Fixtures.result())

        XCTAssertEqual(
            session.controller.toolStatus(for: childId),
            .completed,
            ".result must clear .running tool surfaces end-to-end")
    }

    /// Replay-mode `.result` (history JSONL) does NOT fire
    /// `onTurnFinishedLive`. Historical entries shouldn't be `.running`
    /// in the first place — but this lock-step the no-op contract so
    /// future refactors don't accidentally fire it during JSONL
    /// playback.
    func testReplayResultDoesNotFireSink() {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository()
        )
        var fired = false
        runtime.onTurnFinishedLive = { fired = true }

        runtime.receive(Message2Fixtures.result(), mode: .replay)

        XCTAssertFalse(
            fired, "replay-mode .result must not fire onTurnFinishedLive")
    }
}

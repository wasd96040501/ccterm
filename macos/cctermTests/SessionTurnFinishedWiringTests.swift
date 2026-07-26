import AgentSDK
import XCTest

@testable import ccterm

/// Guards the runtime's live-vs-replay discrimination for the
/// `onTurnFinishedLive` hook: a `.result` received from the live CLI
/// fires it, while a `.result` replayed from history JSONL must not.
/// Historical entries are never `.running` in the first place, so
/// firing the hook during playback would be spurious.
@MainActor
final class SessionTurnFinishedWiringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Live `.result` fires `onTurnFinishedLive` synchronously.
    func testLiveResultFiresTurnFinishedSink() {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository()
        )
        var fired = false
        runtime.onTurnFinishedLive = { fired = true }

        runtime.receive(Message2Fixtures.result())

        XCTAssertTrue(
            fired, "live .result must fire onTurnFinishedLive")
    }

    /// Replay-mode `.result` (history JSONL) does NOT fire
    /// `onTurnFinishedLive`. Locks the no-op contract so future
    /// refactors don't accidentally fire it during JSONL playback.
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

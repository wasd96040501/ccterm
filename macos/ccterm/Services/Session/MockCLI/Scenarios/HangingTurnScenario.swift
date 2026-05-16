#if DEBUG

import Foundation

/// "Turn hangs forever" scenario: after host sends a user message, the mock
/// echoes but does not emit a result. `isRunning` stays true until the host
/// sends `interrupt`, which the base's default `onInterrupt` then closes.
///
/// Used by `InputBar2StopButtonUITests` to verify the stop button actually
/// interrupts a turn. Other control_requests (initialize, etc.) take the
/// `MockCLIBaseScenario` defaults; only one hook differs here.
final class HangingTurnScenario: MockCLIBaseScenario {
    override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
        if let uuid {
            send.echoUser(text: text, uuid: uuid, sessionId: sessionId)
        }
        // Deliberately no result — turn stays hung.
    }
}

#endif

#if DEBUG

import Foundation

/// Seeds the transcript with deterministic assistant text that exercises
/// in-transcript search: two messages contain "apple", one does not. The
/// search bar UI test types "apple" and verifies the counter (1 / 2),
/// next / previous wrap-around, and ESC dismiss against this fixture.
///
/// Three messages because we want a non-hit between the two hits — that
/// catches off-by-one bugs in the cursor that pure two-hit scans miss.
final class SearchableContentScenario: MockCLIBaseScenario {
    override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
        if let uuid {
            send.echoUser(text: text, uuid: uuid, sessionId: sessionId)
        }
        send.sendAssistantText(
            "apple banana cherry",
            sessionId: sessionId)
        send.sendAssistantText(
            "nothing fruity in this line",
            sessionId: sessionId)
        send.sendAssistantText(
            "second apple sighting, plus other words",
            sessionId: sessionId)
        send.sendResultSuccess(sessionId: sessionId)
    }
}

#endif

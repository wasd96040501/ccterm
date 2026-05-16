import XCTest

/// Verifies that InputBar2's stop button actually interrupts a running turn.
///
/// Walks the full "type → send → CLI hangs → click stop → CLI acks" flow with a
/// mock CLI (`hangingTurn` scenario: deliberately withholds the result frame
/// until it receives an interrupt, then acks with `result.error_during_execution`).
/// No real Claude CLI involved, no Core Data writes.
///
/// Test-mode wiring is documented in [cctermUITests/CLAUDE.md](CLAUDE.md):
/// - `CCTERM_TEST_MODE=1` installs the in-memory repo + mock CLI override.
/// - `CCTERM_MOCK_CLI_SCENARIO=hangingTurn` makes the child process run `HangingTurnScenario`.
final class InputBar2StopButtonUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStopButtonCancelsRunningState() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "hangingTurn",
        ]
        app.launch()

        let sendButton = app.buttons["InputBar2.SendButton"]
        let stopButton = app.buttons["InputBar2.StopButton"]

        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 10),
            "send button should be present on launch")
        XCTAssertFalse(stopButton.exists, "stop button should not be visible before sending")

        // NSTextView doesn't accept a11y queries directly — click to the left of the
        // send button to focus the underlying InputTextView, then type.
        let barCenter = sendButton.coordinate(withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
        barCenter.click()
        app.typeText("hi")
        app.typeKey("\r", modifierFlags: .command)

        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 5),
            "stop button should appear after sending (mock CLI holds turn)")
        XCTAssertFalse(sendButton.exists, "send button should be hidden while running")

        stopButton.click()

        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 3),
            "send button should return after stop (interrupt resets pendingTurnCount)")
        XCTAssertFalse(stopButton.exists, "stop button should be gone after interrupt")
    }
}

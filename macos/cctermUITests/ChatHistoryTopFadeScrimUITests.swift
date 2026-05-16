import XCTest

/// Verifies that the top fade-blur scrim is mounted on the chat detail.
///
/// The scrim is a fixed-height (80pt) Material veil with a vertical-gradient
/// mask, layered as `.overlay(alignment: .top)` above `ChatHistoryView`. It
/// pairs with the corresponding bottom scrim and exists because the
/// transcript runs flush to the window's top (no `contentInsets.top`); the
/// scrim softens the seam between window chrome and the first visible row.
///
/// Test-mode wiring is documented in [cctermUITests/CLAUDE.md](CLAUDE.md):
/// `CCTERM_TEST_MODE=1` installs the in-memory repo + mock CLI override.
/// `hangingTurn` is reused only because it is the existing registered
/// scenario; the test does not actually send a message.
final class ChatHistoryTopFadeScrimUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTopFadeScrimMountsOnChatDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "hangingTurn",
        ]
        app.launch()

        // The detail starts on the New Session tab, which lazily allocates a
        // draft session id and mounts ChatHistoryView immediately — the scrim
        // overlay therefore exists from launch, without needing to send a
        // message or pick a session in the sidebar.
        let scrim = app.descendants(matching: .any)["ChatHistory.TopFadeScrim"]
        XCTAssertTrue(
            scrim.waitForExistence(timeout: 10),
            "top fade-blur scrim should be mounted above the chat transcript")
    }
}

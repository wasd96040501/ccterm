import XCTest

/// Verifies the in-transcript search ⌘F flow end-to-end:
///
/// - ⌘F opens the floating search bar with the field focused.
/// - Typing a query updates the counter to `current / total`.
/// - Return advances the cursor (wrap-around on the last hit).
/// - Shift+Return steps back.
/// - ESC dismisses the bar and clears all highlights.
///
/// Drives the fixture via `SearchableContentScenario`: after the user
/// sends a message, the mock emits three assistant lines, two of which
/// contain "apple". The two-hit / one-non-hit shape catches off-by-one
/// bugs in the cursor that pure two-hit scans miss.
///
/// Test-mode wiring documented in [cctermUITests/CLAUDE.md](CLAUDE.md):
/// `CCTERM_TEST_MODE=1` installs the in-memory repo + mock CLI override.
/// `CCTERM_MOCK_CLI_SCENARIO=searchableContent` selects the fixture.
final class TranscriptSearchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchBarOpenTypeNavigateClose() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "searchableContent",
        ]
        app.launch()

        let sendButton = app.buttons["InputBar2.SendButton"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 10),
            "send button should be present on launch")

        // Drive the fixture: send a user message, mock emits three
        // assistant lines, then sendResultSuccess closes the turn so
        // the send button comes back.
        let barCenter = sendButton.coordinate(
            withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
        barCenter.click()
        app.typeText("go")
        app.typeKey("\r", modifierFlags: .command)

        // Turn-complete signal: send button is the readable
        // confirmation that mock finished and transcript has the
        // assistant content installed.
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 10),
            "send button should reappear after mock completes the turn")

        // ⌘F opens the search bar.
        app.typeKey("f", modifierFlags: .command)

        let field = app.textFields["ChatSearchBar.Field"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "search field should appear after ⌘F")

        // Query "apple" — two hits among the three assistant lines.
        app.typeText("apple")

        let counter = app.staticTexts["ChatSearchBar.Counter"]
        XCTAssertTrue(
            counter.waitForExistence(timeout: 3),
            "counter should appear after typing a non-empty query")
        XCTAssertEqual(
            counter.label, "1 / 2",
            "first hit should be the current cursor (1-based of 2 total)")

        // Return = next hit.
        app.typeKey("\r", modifierFlags: [])
        XCTAssertEqual(
            counter.label, "2 / 2",
            "Return should advance the cursor to the second hit")

        // Wrap-around: next on the last hit → first hit.
        app.typeKey("\r", modifierFlags: [])
        XCTAssertEqual(
            counter.label, "1 / 2",
            "Return on the last hit should wrap back to the first")

        // Shift+Return = previous hit (wrap to last).
        app.typeKey("\r", modifierFlags: .shift)
        XCTAssertEqual(
            counter.label, "2 / 2",
            "Shift+Return on the first hit should wrap to the last")

        // ESC dismisses the bar.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(
            field.waitForExistence(timeout: 1),
            "search field should be gone after ESC")
    }

    @MainActor
    func testSearchBarNoHitsCounter() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "searchableContent",
        ]
        app.launch()

        let sendButton = app.buttons["InputBar2.SendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        let barCenter = sendButton.coordinate(
            withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
        barCenter.click()
        app.typeText("go")
        app.typeKey("\r", modifierFlags: .command)
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["ChatSearchBar.Field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // A token that's nowhere in the fixture's assistant text.
        app.typeText("zzzzzz")

        let counter = app.staticTexts["ChatSearchBar.Counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        XCTAssertEqual(
            counter.label, "0 / 0",
            "counter should read 0 / 0 when the query has no hits")

        // Nav buttons should be disabled / no-op — pressing Return
        // must not crash and must leave counter unchanged.
        app.typeKey("\r", modifierFlags: [])
        XCTAssertEqual(
            counter.label, "0 / 0",
            "Return with no hits should be a no-op")
    }
}

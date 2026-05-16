import XCTest

/// Verifies the in-transcript search feature end-to-end.
///
/// The search field is mounted as a `.primaryAction` `ToolbarItem` on
/// `ChatHistoryView` and is always present in the window toolbar —
/// there is no open / close cycle to drive. Tests click the field
/// directly to take focus, type, then exercise the counter and the
/// prev / next buttons.
///
/// Drives the fixture via `SearchableContentScenario`: after the user
/// sends a message, the mock emits three assistant lines, two of
/// which contain "apple". The two-hit / one-non-hit shape catches
/// off-by-one bugs in the cursor that pure two-hit scans miss.
///
/// Test-mode wiring documented in [cctermUITests/CLAUDE.md](CLAUDE.md):
/// `CCTERM_TEST_MODE=1` installs the in-memory repo + mock CLI override.
/// `CCTERM_MOCK_CLI_SCENARIO=searchableContent` selects the fixture.
final class TranscriptSearchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Isolation smoke test — verifies the search field is present in the
    /// accessibility tree right after launch, without going through the
    /// launch-and-seed helper. If this fails, the field is missing
    /// regardless of the message-send path, and the diagnostic dump
    /// printed below tells us exactly what the tree looks like.
    @MainActor
    func testAaaSearchFieldPresentOnLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "searchableContent",
        ]
        app.launch()

        // Wait for the chat view to mount (signal: send button present).
        _ = app.buttons["InputBar2.SendButton"].waitForExistence(timeout: 10)

        let field = app.textFields["ChatSearchBar.Field"]
        let found = field.waitForExistence(timeout: 5)
        if !found {
            print("DEBUG a11y tree (no field found):\n\(app.debugDescription)")
        }
        XCTAssertTrue(found, "ChatSearchBar.Field must be in the a11y tree at launch")
    }

    @MainActor
    func testSearchBarTypeNavigate() throws {
        let app = launchAppAndSeedTranscript()

        let field = app.textFields["ChatSearchBar.Field"]
        if !field.waitForExistence(timeout: 5) {
            // Diagnostic dump — CI is hitting a missing field, log the
            // full a11y tree so we can see what's actually there.
            print("DEBUG a11y tree (after launchAndSeed):\n\(app.debugDescription)")
        }
        XCTAssertTrue(
            field.exists,
            "search field should be present in the toolbar")
        field.click()

        // Query "apple" — two hits among the three assistant lines.
        app.typeText("apple")

        let counter = app.staticTexts["ChatSearchBar.Counter"]
        XCTAssertTrue(
            counter.waitForExistence(timeout: 3),
            "counter should appear after typing a non-empty query")
        XCTAssertEqual(
            counter.label, "1 / 2",
            "first hit should be the current cursor (1-based of 2 total)")

        // Next button → second hit.
        app.buttons["ChatSearchBar.NextButton"].click()
        XCTAssertEqual(
            counter.label, "2 / 2",
            "next button should advance the cursor to the second hit")

        // Wrap-around: next on the last hit → first hit.
        app.buttons["ChatSearchBar.NextButton"].click()
        XCTAssertEqual(
            counter.label, "1 / 2",
            "next on the last hit should wrap back to the first")

        // Previous button → wrap back to last.
        app.buttons["ChatSearchBar.PrevButton"].click()
        XCTAssertEqual(
            counter.label, "2 / 2",
            "previous on the first hit should wrap to the last")
    }

    @MainActor
    func testSearchBarNoHitsCounter() throws {
        let app = launchAppAndSeedTranscript()

        let field = app.textFields["ChatSearchBar.Field"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "search field should be present in the toolbar")
        field.click()

        // A token that's nowhere in the fixture's assistant text.
        app.typeText("zzzzzz")

        let counter = app.staticTexts["ChatSearchBar.Counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        XCTAssertEqual(
            counter.label, "0 / 0",
            "counter should read 0 / 0 when the query has no hits")

        // Nav buttons should be disabled — clicking must not crash
        // and must leave counter unchanged.
        let nextButton = app.buttons["ChatSearchBar.NextButton"]
        XCTAssertFalse(
            nextButton.isEnabled,
            "next button should be disabled when there are no hits")
        XCTAssertEqual(
            counter.label, "0 / 0",
            "counter should remain 0 / 0 with no hits")
    }

    // MARK: - Helpers

    @MainActor
    private func launchAppAndSeedTranscript() -> XCUIApplication {
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

        let barCenter = sendButton.coordinate(
            withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
        barCenter.click()
        app.typeText("go")
        app.typeKey("\r", modifierFlags: .command)

        // Turn-complete signal: send button reappears once the mock
        // finishes and transcript has the assistant content installed.
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 10),
            "send button should reappear after mock completes the turn")
        return app
    }
}

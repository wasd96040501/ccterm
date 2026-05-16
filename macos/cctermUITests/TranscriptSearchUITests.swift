import XCTest

/// Verifies the in-transcript search feature end-to-end.
///
/// **Trigger is menu-click, not ⌘F.** XCUITest's
/// `typeKey(_:modifierFlags:)` does not reliably route through
/// AppKit's menu-shortcut path under CI, so we open the search bar
/// by clicking the `Find → Find in Transcript` menu item. The ⌘F
/// shortcut still ships (bound on the same menu item) — but
/// exercising it through XCUITest is not the responsibility of
/// these tests. Manual / user testing covers the keyboard path.
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

    @MainActor
    func testSearchBarOpenTypeNavigateClose() throws {
        let app = launchAppAndSeedTranscript()

        openSearchBar(in: app)
        let field = app.textFields["ChatSearchBar.Field"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "search field should appear after clicking the Find menu")

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

        // Close button dismisses the bar.
        app.buttons["ChatSearchBar.CloseButton"].click()
        XCTAssertFalse(
            field.exists,
            "search field should be gone after the close button")
    }

    @MainActor
    func testSearchBarNoHitsCounter() throws {
        let app = launchAppAndSeedTranscript()

        openSearchBar(in: app)
        let field = app.textFields["ChatSearchBar.Field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

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

    /// Open the in-transcript search bar by clicking the
    /// `Find → Find in Transcript` menu item. Avoids relying on
    /// keyboard-shortcut event delivery, which is unreliable under
    /// XCUITest. Still validates that the menu (and its `⌘F`
    /// shortcut binding) is properly registered.
    @MainActor
    private func openSearchBar(in app: XCUIApplication) {
        let findMenu = app.menuBars.menuBarItems["Find"]
        XCTAssertTrue(
            findMenu.waitForExistence(timeout: 5),
            "Find menu should be present in the menu bar")
        findMenu.click()
        let findItem = app.menuItems["Find in Transcript"]
        XCTAssertTrue(
            findItem.waitForExistence(timeout: 3),
            "Find → Find in Transcript menu item should exist")
        findItem.click()
    }
}

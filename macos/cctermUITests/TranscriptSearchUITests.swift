import XCTest

/// Verifies the in-transcript search feature end-to-end.
///
/// The search field is mounted in `ChatHistoryView`'s top toolbar
/// strip and is always present — there is no open / close cycle to
/// drive. Tests click the field directly to take focus, type, then
/// exercise the counter and the prev / next buttons.
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
    func testSearchBarTypeNavigate() throws {
        let app = launchAppAndSeedTranscript()

        let field = app.textFields["ChatSearchBar.Field"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "search field should be present in the toolbar")
        field.click()

        // Query "apple" — two hits among the three assistant lines.
        app.typeText("apple")

        let counter = app.staticTexts["ChatSearchBar.Counter"]
        XCTAssertTrue(
            counter.waitForExistence(timeout: 3),
            "counter should appear after typing a non-empty query")
        // SwiftUI `Text` on macOS exposes its content via AX `value`
        // (AXStaticText.AXValue), not `label`. `.label` is empty.
        XCTAssertEqual(
            counter.value as? String, "1 / 2",
            "first hit should be the current cursor (1-based of 2 total)")

        // Next button → second hit.
        app.buttons["ChatSearchBar.NextButton"].click()
        XCTAssertEqual(
            counter.value as? String, "2 / 2",
            "next button should advance the cursor to the second hit")

        // Wrap-around: next on the last hit → first hit.
        app.buttons["ChatSearchBar.NextButton"].click()
        XCTAssertEqual(
            counter.value as? String, "1 / 2",
            "next on the last hit should wrap back to the first")

        // Previous button → wrap back to last.
        app.buttons["ChatSearchBar.PrevButton"].click()
        XCTAssertEqual(
            counter.value as? String, "2 / 2",
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
        // See `testSearchBarTypeNavigate` for why `.value` instead of
        // `.label`: AXStaticText surfaces its content as AXValue.
        XCTAssertEqual(
            counter.value as? String, "0 / 0",
            "counter should read 0 / 0 when the query has no hits")

        // Nav buttons should be disabled — clicking must not crash
        // and must leave counter unchanged.
        let nextButton = app.buttons["ChatSearchBar.NextButton"]
        XCTAssertFalse(
            nextButton.isEnabled,
            "next button should be disabled when there are no hits")
        XCTAssertEqual(
            counter.value as? String, "0 / 0",
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

import XCTest

/// Verifies the in-transcript search feature end-to-end.
///
/// The search field is `TranscriptSearchOverlayView` — an
/// `NSSearchField` wrapped via `NSViewRepresentable` and floated as an
/// `.overlay(alignment: .top)` at the top-trailing corner of
/// `ChatHistoryView`. It's always mounted; tests click it to take
/// focus, type, then exercise navigation via keyboard:
///
/// - `Return` advances to the next match (the cell's action target
///   calls `controller.nextSearchHit()`).
/// - `Shift+Return` steps to the previous match
///   (`control(_:textView:doCommandBy:)` intercepts `insertNewline:`
///   when `NSApp.currentEvent.modifierFlags` contains `.shift`).
///
/// There is no counter / prev / next chrome to observe — we assert the
/// smoke path: the field accepts typing, retains its value across
/// Return / Shift+Return, and the navigation does not crash the
/// runner. Because the field is an `NSSearchField`, XCUITest still
/// queries it via `app.searchFields.firstMatch`.
///
/// Drives the fixture via `SearchableContentScenario`: after the user
/// sends a message, the mock emits three assistant lines, two of
/// which contain "apple".
///
/// Test-mode wiring documented in [cctermUITests/CLAUDE.md](CLAUDE.md):
/// `CCTERM_TEST_MODE=1` installs the in-memory repo + mock CLI override.
/// `CCTERM_MOCK_CLI_SCENARIO=searchableContent` selects the fixture.
final class TranscriptSearchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchFieldTypeAndKeyboardNavigate() throws {
        let app = launchAppAndSeedTranscript()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "search field overlay should be present at top-trailing of the chat")
        field.click()

        // Query "apple" — two hits among the three assistant lines.
        app.typeText("apple")
        XCTAssertEqual(
            field.value as? String, "apple",
            "search field value should reflect the typed query")

        // Plain Return advances to the next match. Shift+Return steps
        // back. The runs are smoke checks: navigation must not crash
        // and the field must retain focus / text.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(
            field.value as? String, "apple",
            "search field should retain its query after Return (next)")

        app.typeKey(.return, modifierFlags: .shift)
        XCTAssertEqual(
            field.value as? String, "apple",
            "search field should retain its query after Shift+Return (previous)")
    }

    /// ⌘F from anywhere should focus the search field. The shortcut is
    /// wired through `AppCommands` → `TranscriptSearchBus.requestFocus()`
    /// → `ChatHistoryView.isSearchFocused`.
    @MainActor
    func testCommandFFocusesSearchField() throws {
        let app = launchAppAndSeedTranscript()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "search field overlay should be present at top-trailing of the chat")

        app.typeKey("f", modifierFlags: .command)
        // Typing immediately after the focus shortcut should land in
        // the field; reading `.value` confirms the keystrokes were
        // routed there.
        app.typeText("zz")
        XCTAssertEqual(
            field.value as? String, "zz",
            "⌘F should focus the search field so subsequent typing lands in it")
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
        // 15s rather than 10s: the searchable fixture emits three
        // assistant lines before `result.success`, and the first test
        // of the class also eats cold-launch latency on the CI VM —
        // 10s has been observed to tail-clip just past the deadline.
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 15),
            "send button should reappear after mock completes the turn")
        return app
    }
}

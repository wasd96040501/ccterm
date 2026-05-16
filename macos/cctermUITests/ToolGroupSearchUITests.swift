import XCTest

/// Smoke check that in-transcript search keeps working when the transcript
/// carries a tool group block. The matching fixture is
/// `toolGroupSearchableContent` — a Bash tool call whose stdout text is
/// searchable, plus one trailing assistant text message that gives the
/// scan something to land on at the top level (tool groups default to
/// folded, and unfolding a chevron drawn into a self-drawn
/// `BlockCellView` cannot be addressed through XCUITest's AX queries).
///
/// What this test covers vs. what it doesn't:
///
/// - Covered: `Transcript2SearchCoordinator.runQuery` walks every
///   block including the tool group; `expandForSearchHit(blockId:position:)`
///   is invoked with the new `position` parameter on Return / Shift+Return.
///   Regression guard for the API change that paired the search-side
///   position with the coordinator-side child-precise unfold.
/// - Not covered: the visual auto-expand on nav. That requires either
///   clicking the chevron (no stable AX handle on the self-drawn cell)
///   or programmatic fold-toggle (forbidden production test hook). The
///   precise behaviour is unit-tested in
///   `cctermTests/ToolGroupSearchableRegionsTests.swift`.
final class ToolGroupSearchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchOverTranscriptWithToolGroupDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "toolGroupSearchableContent",
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

        // Turn-complete: mock emits user echo, tool_use + tool_result,
        // one assistant text, then result.success — wait for the send
        // button to come back. 15s like the sibling search test class
        // because the first launch eats cold-start latency on CI.
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 15),
            "send button should reappear after the mock completes the turn")

        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "search field should be present in the toolbar")
        field.click()
        app.typeText("apple")
        XCTAssertEqual(
            field.value as? String, "apple",
            "search field should reflect the typed query over a tool-group transcript")

        // Return drives navigateToCurrent → expandForSearchHit with the
        // new (blockId:position:) signature. The plain assistant text
        // gives us a hit to land on; the toolGroup row stays folded
        // and contributes nothing to the scan — but the scanner does
        // walk it, exercising ToolGroupLayout.selectionAdapter under
        // a tool group's presence in the document.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(
            field.value as? String, "apple",
            "search field should retain its query after Return (next) over a tool-group transcript")

        app.typeKey(.return, modifierFlags: .shift)
        XCTAssertEqual(
            field.value as? String, "apple",
            "search field should retain its query after Shift+Return (previous) over a tool-group transcript")
    }
}

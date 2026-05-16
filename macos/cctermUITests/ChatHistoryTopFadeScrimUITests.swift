import XCTest

/// Verifies that the chat transcript runs flush to the window's top edge —
/// no toolbar / chrome strip between the window's top and the first row.
///
/// The top fade-blur scrim is a fixed-height (80pt) Material veil layered
/// as `.overlay(alignment: .top)` above `ChatHistoryView`. Its top edge
/// sits exactly at the top of `ChatHistoryView`, so comparing
/// `scrim.frame.minY` to `window.frame.minY` is a direct test of the
/// "transcript flush to top" invariant. If `.searchable` (or anything
/// else) reserves a chrome band above the content, the scrim's top
/// shifts down by the chrome height and the assertion fires.
///
/// Test-mode wiring is documented in [cctermUITests/CLAUDE.md](CLAUDE.md):
/// `CCTERM_TEST_MODE=1` installs the in-memory repo + mock CLI override.
/// `hangingTurn` is reused only because it is the existing registered
/// scenario; the test does not actually send a message.
final class ChatHistoryTopFadeScrimUITests: XCTestCase {

    /// Tolerance in screen points for the scrim-vs-window top-edge
    /// comparison. The two should match exactly under a hidden title
    /// bar with the toolbar background hidden, but AppKit's window
    /// shadow / border can shift the AX-reported window frame by a
    /// fraction of a point; 4pt absorbs that without admitting a real
    /// toolbar strip (~38pt) as a false negative.
    private static let topAlignmentTolerance: CGFloat = 4

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTopFadeScrimMountsOnChatDetail() throws {
        let app = launchTestApp()

        let scrim = app.descendants(matching: .any)["ChatHistory.TopFadeScrim"]
        XCTAssertTrue(
            scrim.waitForExistence(timeout: 10),
            "top fade-blur scrim should be mounted above the chat transcript")
    }

    /// Asserts the scrim's top edge matches the window's top edge — i.e.
    /// the transcript runs flush to the window top with no toolbar /
    /// chrome strip pushing it down.
    ///
    /// `.searchable(placement: .toolbar)` would normally reserve a
    /// ~38pt band at the top of the detail pane; the production code
    /// cancels that by hiding the toolbar background
    /// (`.toolbarBackground(.hidden, for: .windowToolbar)`) and
    /// ignoring the top safe area (`.ignoresSafeArea(edges: .top)`).
    /// This test is the guard that those two modifiers remain in
    /// place; removing either makes `scrim.frame.minY` drop below
    /// `window.frame.minY` by the toolbar height.
    @MainActor
    func testTranscriptFlushToWindowTop() throws {
        let app = launchTestApp()

        let scrim = app.descendants(matching: .any)["ChatHistory.TopFadeScrim"]
        XCTAssertTrue(
            scrim.waitForExistence(timeout: 10),
            "top fade-blur scrim should be mounted above the chat transcript")

        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "main window should exist")

        let windowTopY = window.frame.minY
        let scrimTopY = scrim.frame.minY
        let delta = scrimTopY - windowTopY

        XCTAssertLessThanOrEqual(
            abs(delta), Self.topAlignmentTolerance,
            "scrim top should align with window top (transcript flush to top); "
                + "delta=\(delta)pt — a positive delta of ~38pt indicates the "
                + ".searchable toolbar is reserving chrome space again "
                + "(missing .toolbarBackground(.hidden, for: .windowToolbar) "
                + "or .ignoresSafeArea(edges: .top)).")
    }

    @MainActor
    private func launchTestApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "hangingTurn",
        ]
        app.launch()
        return app
    }
}

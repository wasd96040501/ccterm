import XCTest

/// Verifies the image-attach flow on `InputBarView2`:
///
/// 1. The attach button (`InputBar2.AttachButton`) is mounted alongside the
///    text field and the send button on launch.
/// 2. Activating the test hook (`InputBar2.TestAttachImage`) — which
///    bypasses `NSOpenPanel` and installs a synthetic in-memory PNG —
///    surfaces the thumbnail (`InputBar2.AttachmentThumbnail`) inside the
///    pill, growing the bar's height.
/// 3. Sending the message with an attachment clears the thumbnail and
///    returns the pill to its single-line layout.
///
/// `NSOpenPanel` is a system-owned modal that XCUITest cannot drive, so the
/// test hook is the only sanctioned entry point in test mode. Production
/// users still go through the Menu → NSOpenPanel path; that branch is not
/// exercised by these tests.
///
/// Scenario: `imageEcho` (inherits `MockCLIBaseScenario` defaults — echo +
/// `result.success`, so the turn completes cleanly and the bar returns to
/// the send-button state). Documented in [cctermUITests/CLAUDE.md](CLAUDE.md).
final class InputBar2AttachImageUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAttachButtonIsPresentOnLaunch() throws {
        let app = launchApp()

        let attachButton = app.descendants(matching: .any)["InputBar2.AttachButton"]
        XCTAssertTrue(
            attachButton.waitForExistence(timeout: 10),
            "attach button should be present on the input bar at launch")

        XCTAssertFalse(
            app.descendants(matching: .any)["InputBar2.AttachmentThumbnail"].exists,
            "thumbnail should not be visible before attaching an image")
    }

    @MainActor
    func testAttachingImageShowsThumbnail() throws {
        let app = launchApp()

        // Wait for the bar to mount, then drive the test hook (which
        // installs the synthetic PNG without opening NSOpenPanel).
        _ = app.descendants(matching: .any)["InputBar2.AttachButton"]
            .waitForExistence(timeout: 10)
        let hook = app.buttons["InputBar2.TestAttachImage"]
        XCTAssertTrue(
            hook.waitForExistence(timeout: 5),
            "test attach hook should be mounted under CCTERM_TEST_MODE")
        hook.click()

        let thumbnail = app.descendants(matching: .any)["InputBar2.AttachmentThumbnail"]
        XCTAssertTrue(
            thumbnail.waitForExistence(timeout: 5),
            "thumbnail should appear inside the pill after attaching an image")
    }

    @MainActor
    func testSendingImageClearsThumbnail() throws {
        let app = launchApp()

        _ = app.descendants(matching: .any)["InputBar2.AttachButton"]
            .waitForExistence(timeout: 10)
        let hook = app.buttons["InputBar2.TestAttachImage"]
        XCTAssertTrue(hook.waitForExistence(timeout: 5))
        hook.click()

        let thumbnail = app.descendants(matching: .any)["InputBar2.AttachmentThumbnail"]
        XCTAssertTrue(
            thumbnail.waitForExistence(timeout: 5),
            "thumbnail must appear before we can send the image")

        let sendButton = app.buttons["InputBar2.SendButton"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 5),
            "send button should be enabled once an image is attached "
                + "(image alone satisfies the canSend gate)")
        sendButton.click()

        // Thumbnail clears synchronously inside `handleSend` (it sets
        // `attachment = nil`), but the SwiftUI rebuild may need a tick to
        // remove the a11y node — poll until it disappears.
        let pred = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: pred, object: thumbnail)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 5),
            .completed,
            "thumbnail should be cleared after the image is sent")

        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 5),
            "send button should return after the mock CLI completes the turn")
    }

    // MARK: - Helpers

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CCTERM_TEST_MODE": "1",
            "CCTERM_MOCK_CLI_SCENARIO": "imageEcho",
        ]
        app.launch()
        return app
    }
}

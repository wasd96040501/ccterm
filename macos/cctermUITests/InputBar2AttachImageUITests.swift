import AppKit
import XCTest

/// Verifies the image-attach flow on `InputBarView2` against the real UI
/// (SwiftUI `Menu` + AppKit `NSOpenPanel`) — no production-side test
/// hooks. The synthetic PNG is written to `/tmp` by the test runner so
/// the production `Data(contentsOf:)` path is exercised end-to-end.
///
/// ### How the panel is driven
///
/// On macOS 26 `NSOpenPanel.begin(...)` surfaces as a regular *window*
/// — not a `.dialog` and not a `.sheet`. The a11y tree carries
/// `identifier: 'open-panel'` and `title: 'Open'`. Tests query it as
/// `app.windows["open-panel"]`. We drive it the same way a user would
/// when they know the path: ⌘⇧G ("Go to Folder") → type the path →
/// Enter → Open. Apple developer forums document the keyboard flow;
/// the element-type discovery comes from dumping `app.debugDescription`
/// on the CI runner (see [cctermUITests/CLAUDE.md](CLAUDE.md)).
///
/// ### How `SwiftUI.Menu` is addressed
///
/// On macOS 12+ a SwiftUI `Menu` exposes its label as an `image`
/// accessibility element (not a `button`). The identifier therefore sits
/// on the `Image` *inside* the label closure, and tests query
/// `app.images["InputBar2.AttachButton"]`.
///
/// Scenario: `imageEcho` (inherits `MockCLIBaseScenario` defaults — echo +
/// `result.success`). The turn completes cleanly so the bar returns to
/// the send-button state. Documented in [cctermUITests/CLAUDE.md](CLAUDE.md).
final class InputBar2AttachImageUITests: XCTestCase {

    private let testImagePath = "/tmp/ccterm-ui-test-attach.png"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try writeTestImage(to: testImagePath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: testImagePath)
    }

    @MainActor
    func testAttachButtonIsPresentOnLaunch() throws {
        let app = launchApp()

        let attachButton = attachMenuButton(in: app)
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
        attachImageViaUI(in: app)

        let thumbnail = app.descendants(matching: .any)["InputBar2.AttachmentThumbnail"]
        XCTAssertTrue(
            thumbnail.waitForExistence(timeout: 5),
            "thumbnail should appear inside the pill after attaching an image")
    }

    @MainActor
    func testSendingImageClearsThumbnail() throws {
        let app = launchApp()
        attachImageViaUI(in: app)

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
        // `attachment = nil`); SwiftUI may need a tick to remove the
        // a11y node — poll for absence.
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

    /// SwiftUI `Menu` on macOS 26 renders as a `MenuButton` whose
    /// `accessibilityIdentifier` is swallowed — the only stable handle is
    /// the `accessibilityLabel` we set on the production Menu. Tests
    /// query the MenuButton by that label, which doubles as the
    /// screen-reader-friendly description ("Attach image or file").
    @MainActor
    private func attachMenuButton(in app: XCUIApplication) -> XCUIElement {
        app.menuButtons["Attach image or file"]
    }

    /// Drive the real attach flow: open Menu → click Image → drive
    /// `NSOpenPanel` via ⌘⇧G with the test file path → Open.
    @MainActor
    private func attachImageViaUI(in app: XCUIApplication) {
        let attachButton = attachMenuButton(in: app)
        XCTAssertTrue(
            attachButton.waitForExistence(timeout: 10),
            "attach button must exist before we can open the menu")
        attachButton.click()

        // Menu item is identified by its localized label. CI runs in
        // English (CLAUDE.md notes the existing convention); local
        // developers need the system input source set to English too.
        let imageItem = app.menuItems["Image"]
        XCTAssertTrue(
            imageItem.waitForExistence(timeout: 5),
            "Menu should contain an 'Image' item")
        imageItem.click()

        // macOS 26 surfaces NSOpenPanel as a Window with identifier
        // 'open-panel' (title 'Open'), not as a `.dialog` or `.sheet`.
        // Discovered via `app.debugDescription` dump from the CI runner.
        let panel = app.windows["open-panel"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 10),
            "NSOpenPanel window 'open-panel' should appear after selecting the Image menu item")

        // ⌘⇧G opens the "Go to Folder" prompt. On macOS 26 it surfaces
        // as a sheet on the open-panel window, with a single textField
        // for the path (not a comboBox as older recipes suggest).
        // Discovered via probe on the CI runner.
        app.typeKey("g", modifierFlags: [.command, .shift])

        let goSheet = panel.sheets.firstMatch
        XCTAssertTrue(
            goSheet.waitForExistence(timeout: 5),
            "Go to Folder sheet should appear on the panel after ⌘⇧G")

        let pathField = goSheet.textFields.firstMatch
        XCTAssertTrue(
            pathField.waitForExistence(timeout: 5),
            "Go to Folder sheet should expose a single path textField")

        // Insert the path via the pasteboard. `typeText` is unreliable
        // here because the field's path-autocomplete inserts suggestion
        // text mid-stream — captured screen recordings show a garbled
        // path like '/tmp/ccterm-ui-test-atta/tmp/ccterm-...png', which
        // leaves the Open button disabled because nothing got selected.
        // Pasting bypasses autocomplete entirely.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(testImagePath, forType: .string)
        pathField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)

        // The sheet's primary action is Return — macOS 26 hides the
        // explicit "Go" button. (Older versions had one; the no-op
        // fallback keeps that path covered.)
        let goButton = goSheet.buttons["Go"]
        if goButton.exists {
            goButton.click()
        } else {
            app.typeKey(.return, modifierFlags: [])
        }

        // Wait for Open to *enable* — that's the proof the file was
        // actually selected. A disabled Open button can still be
        // clicked under XCUITest but does nothing.
        let openButton = panel.buttons["Open"]
        XCTAssertTrue(
            openButton.waitForExistence(timeout: 5),
            "Open button should be present on NSOpenPanel after navigation")

        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: enabled, object: openButton)],
                timeout: 5),
            .completed,
            "Open button should become enabled once the file is selected")
        openButton.click()
    }

    /// Write a tiny 16×16 solid-blue PNG to `path`. Production code reads
    /// it via `Data(contentsOf:)`; `UTType(filenameExtension: "png")`
    /// resolves the media type to `image/png`.
    private func writeTestImage(to path: String) throws {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw NSError(
                domain: "InputBar2AttachImageUITests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "could not encode test PNG"])
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}

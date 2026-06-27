import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders the AppKit-rooted main window (sidebar + detail VC,
/// compose-mode default state) into an offscreen NSWindow, captures a
/// PNG, and attaches it to the xcresult. Used to verify the visual
/// layout after the SwiftUI `Window`-scene → AppKit
/// `NSWindowController` migration didn't regress sidebar / detail /
/// scrim / input bar positioning.
///
/// Like the SwiftUI snapshot tests in this target, the test is
/// review-only — no golden-image gate. `make test-unit` skips this
/// class unless explicitly filtered in
/// (`make test-unit FILTER=MainWindowAppKitSnapshotTests`).
@MainActor
final class MainWindowAppKitSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComposeModeSnapshot() throws {
        let appState = AppState()
        let model = MainSelectionModel()
        // Default: compose mode (`__new_session__` tag).

        let split = MainSplitViewController(
            model: model, appState: appState)

        let size = CGSize(width: 1200, height: 800)
        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentViewController = split
        window.setContentSize(size)
        window.ccterm_orderFrontForTesting()

        split.view.frame = CGRect(origin: .zero, size: size)
        split.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        split.view.layoutSubtreeIfNeeded()

        let host = split.view
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("bitmapImageRepForCachingDisplay returned nil")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)

        let url = ViewSnapshot.writePNG(image, name: "MainWindowAppKit-ComposeMode")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "MainWindowAppKit-ComposeMode.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)

        window.contentViewController = nil
        window.close()
    }
}

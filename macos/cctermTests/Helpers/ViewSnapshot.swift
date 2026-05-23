import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Scaffold for screenshotting an arbitrary SwiftUI view from a unit
/// test, *exactly as it would render in the release build*.
///
/// The view is mounted through `NSHostingController` — the AppKit
/// container that every SwiftUI scene sits on top of — parked in a
/// fresh, transparent, off-screen `NSWindow`. Hosting inside a
/// window gives the view tree a real responder chain so `body`
/// computes correctly under production-style geometry; the explicit
/// run-loop drain below lets AppKit's deferred layout passes and
/// any main-actor work queued during view construction settle into
/// pixels before the snapshot is taken.
///
/// **Silence**: `CCTermApp.isUnderXCTest` swizzles
/// `makeKeyAndOrderFront` / `orderFront` / `orderFrontRegardless` to
/// no-ops at process start, so the snapshot window can never reach a
/// visible space through normal AppKit paths. We additionally:
/// - Park the window at `(-30_000, -30_000)` so a hypothetical
///   auto-constrain back onto a screen would land off any real
///   display.
/// - Set `alphaValue = 0.01` so AppKit treats the window as on-screen
///   for layout purposes (occlusion ↔ layout interplay) while the
///   user sees nothing.
/// - Call `ccterm_orderFrontForTesting()` (a test-only escape hatch
///   on `NSWindow`) instead of the public `makeKeyAndOrderFront(_:)`,
///   so the bypass is scoped to this one window and does not relax
///   the swizzle for the rest of the process.
///
/// **State seeding**: SwiftUI's `.task` / `.onAppear` modifiers
/// require an appearance signal from AppKit that this offscreen
/// hosted window cannot deliver reliably under XCTest. Views that
/// seed their controller / model from `.task` should expose a test
/// init that accepts a pre-built state object and pass that into the
/// snapshot. The view itself stays unchanged in production behavior
/// — the test seam is purely an additional initializer.
enum ViewSnapshot {

    /// Render `view` at `size` and return the resulting `NSImage`.
    ///
    /// `settle` drains the main run loop long enough for AppKit's
    /// deferred layout (`NSTableView.noteHeightOfRows` passes,
    /// `viewDidEndLiveResize` followups, etc.) to land in the
    /// backing store before the snapshot is taken.
    @MainActor
    static func render(
        _ view: some View,
        size: CGSize,
        settle: TimeInterval = 0.4
    ) -> NSImage {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentViewController = controller
        window.ccterm_orderFrontForTesting()

        controller.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        controller.view.layoutSubtreeIfNeeded()

        let host = controller.view
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("ViewSnapshot: bitmapImageRepForCachingDisplay returned nil")
            return NSImage(size: size)
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)

        window.contentViewController = nil
        window.close()
        return image
    }

    /// Render an AppKit `NSViewController` at `size` and return the
    /// resulting `NSImage`. Parallel to `render(_:size:settle:)` but
    /// for AppKit-rooted hosts (demo / transcript VCs, the sidebar
    /// outline view) that don't go through `NSHostingController`. Same
    /// offscreen-window + alpha-0.01 + ccterm_orderFrontForTesting
    /// scaffolding.
    @MainActor
    static func renderViewController(
        _ controller: NSViewController,
        size: CGSize,
        settle: TimeInterval = 0.4
    ) -> NSImage {
        controller.view.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentViewController = controller
        window.ccterm_orderFrontForTesting()

        controller.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        controller.view.layoutSubtreeIfNeeded()

        let host = controller.view
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("ViewSnapshot: bitmapImageRepForCachingDisplay returned nil")
            return NSImage(size: size)
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)

        window.contentViewController = nil
        window.close()
        return image
    }

    /// PNG-encode `image` and write it to `name.png` under the scratch
    /// directory (configurable via `CCTERM_SCREENSHOT_DIR`, defaults
    /// to `/tmp/ccterm-screenshots`). Returns the URL written.
    @MainActor
    @discardableResult
    static func writePNG(_ image: NSImage, name: String) -> URL {
        let dirPath =
            ProcessInfo.processInfo.environment["CCTERM_SCREENSHOT_DIR"]
            ?? "/tmp/ccterm-screenshots"
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ViewSnapshot: PNG encode failed")
            return url
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            XCTFail("ViewSnapshot: write failed: \(error)")
        }
        return url
    }
}

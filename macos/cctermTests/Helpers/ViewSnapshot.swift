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
/// **Silence**: the window never reaches a visible space —
/// - parked at `(-30_000, -30_000)`, off any real display;
/// - `alphaValue = 0.01`, so AppKit still treats it as on-screen for
///   layout (occlusion ↔ layout interplay) while the user sees nothing.
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
        window.makeKeyAndOrderFront(nil)

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
    /// for AppKit-rooted hosts that don't go through
    /// `NSHostingController`. Same off-screen, alpha-0.01 window.
    /// `beforeCapture` runs once the tree has settled, right before it is
    /// drawn: a state the real pointer would undo on settling (hover — it is
    /// never over the off-screen window) is set there.
    @MainActor
    static func renderViewController(
        _ controller: NSViewController,
        size: CGSize,
        settle: TimeInterval = 0.4,
        beforeCapture: () -> Void = {}
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
        window.makeKeyAndOrderFront(nil)

        controller.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        controller.view.layoutSubtreeIfNeeded()
        beforeCapture()

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

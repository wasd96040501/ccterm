import AppKit
import ScreenCaptureKit
import XCTest

/// A window as the window server composited it, for snapshots of views that
/// `cacheDisplay` draws wrong — text views scrolled inside a scroll view come
/// out of its in-process redraw with lines from two scroll positions laid
/// over each other, where the screen shows them right.
///
/// The window hangs off the main screen's bottom-left corner with one point
/// showing: the window server composites and captures only a window that
/// overlaps a display. `SCShareableContent.currentProcess` lists the process's
/// own windows without a Screen Recording prompt. Nothing is activated.
/// The same sequence as TranscriptKit's own `WindowCapture`.
@MainActor
enum WindowCapture {
    /// A borderless window of `size`, parked and ordered in, showing
    /// `controller`.
    static func window(for controller: NSViewController, size: NSSize, appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = controller
        window.setContentSize(size)
        park(window)
        window.orderFrontRegardless()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// Captures `window` as composited and writes it to
    /// `/tmp/ccterm-screenshots/<name>.png`.
    @discardableResult
    static func capture(_ window: NSWindow, named name: String) async throws -> URL {
        guard #available(macOS 14.4, *) else { throw XCTSkip("capturing an own window needs macOS 14.4") }
        park(window)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
        var image: CGImage?
        // A capture moments after a window was ordered in can fail and the
        // same one a few frames later not.
        for _ in 0..<30 where image == nil {
            try await Task.sleep(for: .milliseconds(50))
            image = try? await captureOnce(window)
        }
        let png = try XCTUnwrap(
            image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) },
            "the window server never captured the window")
        let directory = URL(fileURLWithPath: "/tmp/ccterm-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        return url
    }

    @available(macOS 14.4, *)
    private static func captureOnce(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let listed = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: listed)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func park(_ window: NSWindow) {
        let screen = (window.screen ?? NSScreen.main)?.frame ?? .zero
        var frame = window.frame
        frame.origin = NSPoint(x: screen.minX + 1 - frame.width, y: screen.minY + 1 - frame.height)
        window.setFrame(frame, display: false)
        window.alphaValue = 1
    }
}

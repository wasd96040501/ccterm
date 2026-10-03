import AppKit
import ScreenCaptureKit
import XCTest

/// A view controller as the window server composites it — what the screen
/// shows — rather than `cacheDisplay`'s in-process redraw, which draws
/// translucent text far too dark (tertiary ink at 0.26 comes out near 0.45)
/// and so can't be laid beside the design (`DesignParity`).
///
/// The window is parked a point onto the main screen's corner, so the window
/// server lists it and nobody sees it; ScreenCaptureKit captures this
/// process's own window, which needs no permission. Needs the display awake.
@MainActor
enum CompositedCapture {
    static func render(
        _ controller: NSViewController, size: CGSize, appearance: NSAppearance? = nil, settle: TimeInterval = 0.4
    ) async throws -> NSImage {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentViewController = controller
        window.setContentSize(size)
        let screen = (NSScreen.main ?? NSScreen.screens[0]).frame
        window.setFrameOrigin(NSPoint(x: screen.minX + 1 - size.width, y: screen.minY + 1 - size.height))
        window.orderFront(nil)
        defer {
            window.contentViewController = nil
            window.close()
        }
        controller.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()

        // A capture right after another sometimes fails; a few frames later it doesn't.
        var attempt = 0
        while true {
            attempt += 1
            do {
                let image = try await capture(window)
                return NSImage(cgImage: image, size: size)
            } catch  where attempt < 10 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
    }

    private static func capture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let listed = try XCTUnwrap(
            content.windows.first { $0.windowID == CGWindowID(window.windowNumber) },
            "the window server does not list the window")
        let filter = SCContentFilter(desktopIndependentWindow: listed)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

import AppKit
import ScreenCaptureKit
import XCTest

/// A window as the window server composited it — the pixels a reader would see,
/// materials, shadows and every layer included — taken without the application
/// ever becoming active or asking for Screen Recording.
///
/// `cacheDisplay` redraws a view into a bitmap in-process, which is right for most
/// of what a snapshot is for and wrong for anything the window server composes:
/// an `NSVisualEffectView` comes out flat, and nothing drawn is what was actually
/// put on screen. ScreenCaptureKit captures what was. Two of its parts make that
/// possible from a test:
///
/// - `SCShareableContent.currentProcess` (macOS 14.4) lists the calling process's
///   own windows "without user consent via TCC" — so no Screen Recording prompt,
///   and nothing to grant on a CI runner.
/// - `SCContentFilter(desktopIndependentWindow:)` captures one window whole,
///   whatever is in front of it.
///
/// **Parked one point on screen, never activated.** The window server captures
/// only a window that overlaps a display — one 30 000 points away fails with
/// `-3811` — but one point is enough for the whole window to come back. So the
/// window is moved to hang off the bottom-left corner of its screen with a single
/// point showing, made opaque, and captured there. Nothing is made key and the
/// application is never activated, so whatever the person at the machine is doing
/// keeps the focus. Measured, not assumed: the frontmost application stayed the
/// same through every capture.
///
/// No logic beyond that sequence, per the harness rule in the package's
/// `CLAUDE.md` §5 — what a capture is *of* is the test's business.
@MainActor
enum WindowCapture {

    /// Where captures are written, one PNG per name.
    static let directory = URL(fileURLWithPath: "/tmp/transcriptkit-screenshots")

    /// Captures `window` as composited, and writes it to `directory` as
    /// `<name>.png`. Returns the file.
    @discardableResult
    static func capture(_ window: NSWindow, named name: String) async throws -> URL {
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("capturing an own window without consent needs macOS 14.4")
        }
        park(window)
        await nextFrames(2, of: window)

        let content = try await SCShareableContent.currentProcess
        let listed = try XCTUnwrap(
            content.windows.first { $0.windowID == CGWindowID(window.windowNumber) },
            "the window server does not list the window as this process's")
        let filter = SCContentFilter(desktopIndependentWindow: listed)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    /// Hangs the window off its screen's bottom-left corner with one point
    /// showing, opaque, and draws it.
    private static func park(_ window: NSWindow) {
        let screen = (window.screen ?? NSScreen.main)?.frame ?? .zero
        window.setFrameOrigin(
            NSPoint(
                x: screen.minX + 1 - window.frame.width, y: screen.minY + 1 - window.frame.height))
        window.alphaValue = 1
        window.orderFront(nil)
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// Waits until the display the window is on has shown frames for `seconds` —
    /// long enough for an animation of that duration, started before the wait, to
    /// have finished on screen. The render server's clock rather than a sleep, so
    /// what is waited for is frames, not time the main thread happened to spend.
    static func waitForFrames(of window: NSWindow, spanning seconds: CFTimeInterval) async {
        guard #available(macOS 14.0, *) else { return }
        await frames(of: window) { elapsed, _ in elapsed >= seconds }
    }

    /// Waits for `count` frames — two is enough for a commit made before the wait
    /// to have been composited by the end of it.
    @available(macOS 14.0, *)
    private static func nextFrames(_ count: Int, of window: NSWindow) async {
        await frames(of: window) { _, frames in frames >= count }
    }

    @available(macOS 14.0, *)
    private static func frames(
        of window: NSWindow, until done: @escaping (CFTimeInterval, Int) -> Bool
    ) async {
        // The screen's link, not the window's: a window's link follows the display
        // it was on when made, and a harness window starts on none — measured, a
        // window moved here from thirty thousand points away waited forever.
        guard let screen = window.screen ?? NSScreen.main else { return }
        let ticker = FrameTicker(until: done)
        let link = screen.displayLink(target: ticker, selector: #selector(FrameTicker.tick))
        await withCheckedContinuation { continuation in
            ticker.resume = continuation
            link.add(to: .main, forMode: .common)
        }
        link.invalidate()
    }
}

/// Counts display-link callbacks, and the time they span, until `done` says so —
/// then resumes whoever is waiting.
@MainActor
private final class FrameTicker: NSObject {

    private let done: (CFTimeInterval, Int) -> Bool
    private var start: CFTimeInterval?
    private var frames = 0
    var resume: CheckedContinuation<Void, Never>?

    init(until done: @escaping (CFTimeInterval, Int) -> Bool) {
        self.done = done
    }

    @objc func tick(_ link: CADisplayLink) {
        let start = self.start ?? link.timestamp
        self.start = start
        frames += 1
        guard done(link.timestamp - start, frames), let resume else { return }
        self.resume = nil
        resume.resume()
    }
}

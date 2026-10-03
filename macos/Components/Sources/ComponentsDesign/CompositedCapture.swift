import AppKit
import ScreenCaptureKit

/// A window as the window server composited it — materials, vibrancy and
/// selection highlights included, which `cacheDisplay` draws flat or black.
/// Components' copy of the app's (`cctermTests/Helpers/CompositedCapture.swift`)
/// — it lives in the style page's executable, which renders itself off screen
/// (`--render`) — and like it the twin of
/// TranscriptKit's `WindowCapture`
/// (`Tests/TranscriptKitTests/WindowCapture.swift` explains each step):
/// `SCShareableContent.currentProcess` lists this process's own windows without
/// a Screen Recording prompt, and the window hangs off the main screen's corner
/// with one point showing, which is all the window server needs to capture it.
/// Nothing is activated and the window never takes the key.
///
/// Needs an awake display: with none presenting frames the capture skips.
@MainActor
enum CompositedCapture {
    /// No image can be had on this machine right now (an asleep display,
    /// another process holding the lock) — not a bug.
    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    struct Failed: Error, CustomStringConvertible {
        var description: String
    }


    /// A borderless window holding `controller` at `size`, ordered in where a
    /// capture can reach it.
    static func mount(_ controller: NSViewController, size: NSSize, appearance: NSAppearance?) -> NSWindow {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = Unconstrained(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentViewController = controller
        window.setContentSize(size)
        park(window)
        window.orderFrontRegardless()
        return window
    }

    /// `window` as composited, its content one pixel per backing pixel.
    static func image(of window: NSWindow) async throws -> CGImage {
        guard #available(macOS 14.4, *) else {
            throw Unavailable(description: "capturing an own window without consent needs macOS 14.4")
        }
        try await Lease.take()
        park(window)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
        try await frames(2, of: window)
        // A capture moments after a window was ordered in sometimes fails and
        // the same one a few frames later does not (TranscriptKit measured it).
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await captureOnce(window)
            } catch  where attempt < 30 {
                try await frames(2, of: window)
            }
        }
    }

    private static func park(_ window: NSWindow) {
        let screen = (window.screen ?? NSScreen.main)?.frame ?? .zero
        var frame = window.frame
        frame.origin = NSPoint(x: screen.minX + 1 - frame.width, y: screen.minY + 1 - frame.height)
        window.setFrame(frame, display: false)
        window.alphaValue = 1
    }

    @available(macOS 14.4, *)
    private static func captureOnce(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let listed = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw Failed(description: "the window server does not list the window as this process's")
        }
        let filter = SCContentFilter(desktopIndependentWindow: listed)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Waits for `count` frames of the window's screen, or skips after 5 s of none.
    private static func frames(_ count: Int, of window: NSWindow) async throws {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let ticker = Ticker(count: count)
        let link = screen.displayLink(target: ticker, selector: #selector(Ticker.tick))
        let deadline = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { ticker.finish(presented: false) }
        }
        let presented = await withCheckedContinuation { continuation in
            ticker.resume = continuation
            link.add(to: .main, forMode: .common)
            RunLoop.main.add(deadline, forMode: .common)
        }
        link.invalidate()
        deadline.invalidate()
        guard presented else { throw Unavailable(description: "the display presented no frames in 5 s — asleep, or absent") }
    }

    @MainActor
    private final class Ticker: NSObject {
        private let count: Int
        private var frames = 0
        var resume: CheckedContinuation<Bool, Never>?

        init(count: Int) { self.count = count }

        @objc func tick(_ link: CADisplayLink) {
            frames += 1
            if frames >= count { finish(presented: true) }
        }

        func finish(presented: Bool) {
            resume?.resume(returning: presented)
            resume = nil
        }
    }

    /// One capture at a time across test processes — the lock TranscriptKit's
    /// captures take too, held until the process ends.
    private enum Lease {
        private static var held: Int32?

        static func take() async throws {
            guard held == nil else { return }
            let file = open("/tmp/xctest-screencapturekit.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o666)
            guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let until = Date(timeIntervalSinceNow: 300)
            while flock(file, LOCK_EX | LOCK_NB) != 0 {
                guard Date() < until else {
                    close(file)
                    throw Unavailable(description: "another process held the capture lock for 300 s")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            held = file
        }
    }

    /// A window AppKit does not move back onto a screen.
    private final class Unconstrained: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
}

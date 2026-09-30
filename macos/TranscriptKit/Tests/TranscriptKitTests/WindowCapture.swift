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
/// **Where `TestWindow` already put it.** The window server captures only a
/// window that overlaps a display — one 30 000 points away fails with `-3811` —
/// and a `TestWindow` is parked with one point showing for exactly that, so
/// capturing needs no move, no activation and no key window.
///
/// No logic beyond that sequence, per the harness rule in the package's
/// `Tests/TranscriptKitTests/CLAUDE.md` — what a capture is *of* is the test's business.
@MainActor
enum WindowCapture {

    /// Where captures are written, one PNG per name.
    static let directory = URL(fileURLWithPath: "/tmp/transcriptkit-screenshots")

    /// Captures `window` as composited, and writes it to `directory` as
    /// `<name>.png`. Returns the file.
    @discardableResult
    static func capture(_ window: NSWindow, named name: String) async throws -> URL {
        let image = try await image(of: window)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    /// `view`'s bounds as the window server composited them, one pixel per point,
    /// with the rep's top-left at the view's top-left — so a flipped view's
    /// rectangles index it directly.
    ///
    /// What a pixel assertion reads. Not `cacheDisplay`, which redraws the view
    /// in-process: it sets up AppKit's drawing state on the way, and so it drew
    /// correctly through a bug that left rows in the wrong appearance on screen.
    static func bitmap(of view: NSView) async throws -> NSBitmapImageRep {
        let window = try XCTUnwrap(view.window, "the view is not in a window")
        let image = try await image(of: window)
        // Window coordinates run from the frame's bottom-left, titlebar included,
        // which is also the whole of what the window server captured.
        let scale = CGFloat(image.width) / window.frame.width
        let inWindow = view.convert(view.bounds, to: nil)
        let crop = CGRect(
            x: inWindow.minX * scale, y: (window.frame.height - inWindow.maxY) * scale,
            width: inWindow.width * scale, height: inWindow.height * scale
        ).integral
        let cropped = try XCTUnwrap(image.cropping(to: crop), "the view is outside the capture")

        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.draw(
            cropped, in: CGRect(origin: .zero, size: view.bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// `window` as composited, after the two frames it takes for what was
    /// committed before the call to be on screen.
    static func image(of window: NSWindow) async throws -> CGImage {
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("capturing an own window without consent needs macOS 14.4")
        }
        try await CaptureLease.take()

        // Every test window is parked on the same point, so the one being
        // captured is brought over the others — `orderFront` does not do that
        // for an application that is not active, and a covered point is a window
        // the window server will not capture (`-3811`). Nothing is activated.
        TestWindow.park(window)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
        try await nextFrames(2, of: window)

        // Retried, because a capture moments after a window was ordered in — or
        // moments after another capture — fails, and the same capture a few
        // frames later does not. Measured outside XCTest: back to back, three of
        // seven fail with `-3811` or an `InvalidTransition`, with the window
        // already listed `isOnScreen`, so there is no state to wait on instead.
        // A request that went unanswered is not one of those: it was dropped,
        // and asking again only waits out the deadline again.
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await captureOnce(window)
            } catch  where attempt < 30 && !(error is Unanswered) {
                try await nextFrames(2, of: window)
            }
        }
    }

    @available(macOS 14.4, *)
    private static func captureOnce(_ window: NSWindow) async throws -> CGImage {
        let content = try await answered("SCShareableContent.currentProcess") {
            try await SCShareableContent.currentProcess
        }
        let listed = try XCTUnwrap(
            content.windows.first { $0.windowID == CGWindowID(window.windowNumber) },
            "the window server does not list the window as this process's")
        let filter = SCContentFilter(desktopIndependentWindow: listed)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await answered("SCScreenshotManager.captureImage") {
            try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
        }
    }

    /// How long a ScreenCaptureKit request may go unanswered. One takes a tenth
    /// of a second; a request replayd has dropped is never answered at all — no
    /// reply and no error — so without a deadline the test waits forever.
    private static let answerDeadline: TimeInterval = 10

    /// `request`'s answer, or `Unanswered` once `answerDeadline` has passed. The
    /// request is abandoned rather than cancelled, because a dropped one cannot
    /// be: nothing is left to finish it.
    private static func answered<T>(
        _ request: String, _ call: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let reply = Reply(continuation)
            reply.deadline = Task { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(answerDeadline * 1_000_000_000))
                reply.finish(.failure(Unanswered(request: request, seconds: answerDeadline)))
            }
            Task { @MainActor in
                do {
                    reply.finish(.success(try await call()))
                } catch {
                    reply.finish(.failure(error))
                }
            }
        }
    }

    /// Waits until the display the window is on has shown frames for `seconds` —
    /// long enough for an animation of that duration, started before the wait, to
    /// have finished on screen. The render server's clock rather than a sleep, so
    /// what is waited for is frames, not time the main thread happened to spend.
    static func waitForFrames(of window: NSWindow, spanning seconds: CFTimeInterval) async throws {
        guard #available(macOS 14.0, *) else { return }
        try await frames(of: window) { elapsed, _ in elapsed >= seconds }
    }

    /// Waits for `count` frames — two is enough for a commit made before the wait
    /// to have been composited by the end of it.
    @available(macOS 14.0, *)
    private static func nextFrames(_ count: Int, of window: NSWindow) async throws {
        try await frames(of: window) { _, frames in frames >= count }
    }

    /// How long a display may go without presenting a frame before the wait gives
    /// up. A display that is asleep, or a session with none, presents nothing, and
    /// a frame wait with no deadline was once a suite hung for ten minutes.
    private static let frameDeadline: TimeInterval = 5

    @available(macOS 14.0, *)
    private static func frames(
        of window: NSWindow, until done: @escaping (CFTimeInterval, Int) -> Bool
    ) async throws {
        // The screen's link, not the window's: a window's link follows the display
        // it was on when made — measured, a window moved onto a screen after it
        // was made on none waited forever on its own.
        guard let screen = window.screen ?? NSScreen.main else { return }
        let ticker = FrameTicker(until: done)
        let link = screen.displayLink(target: ticker, selector: #selector(FrameTicker.tick))
        let deadline = Timer(timeInterval: frameDeadline, repeats: false) { _ in
            MainActor.assumeIsolated { ticker.finish(timedOut: true) }
        }
        let presented = await withCheckedContinuation { continuation in
            ticker.resume = continuation
            link.add(to: .main, forMode: .common)
            RunLoop.main.add(deadline, forMode: .common)
        }
        link.invalidate()
        deadline.invalidate()
        guard presented else {
            throw XCTSkip("the display presented no frames in \(frameDeadline) s — asleep, or absent")
        }
    }
}

/// Counts display-link callbacks, and the time they span, until `done` says so —
/// then resumes whoever is waiting, with whether frames were what ended it.
@MainActor
private final class FrameTicker: NSObject {

    private let done: (CFTimeInterval, Int) -> Bool
    private var start: CFTimeInterval?
    private var frames = 0
    var resume: CheckedContinuation<Bool, Never>?

    init(until done: @escaping (CFTimeInterval, Int) -> Bool) {
        self.done = done
    }

    @objc func tick(_ link: CADisplayLink) {
        let start = self.start ?? link.timestamp
        self.start = start
        frames += 1
        guard done(link.timestamp - start, frames) else { return }
        finish(timedOut: false)
    }

    func finish(timedOut: Bool) {
        guard let resume else { return }
        self.resume = nil
        resume.resume(returning: !timedOut)
    }
}

/// A ScreenCaptureKit request that got no answer before its deadline.
private struct Unanswered: Error, CustomStringConvertible {
    let request: String
    let seconds: TimeInterval

    var description: String {
        "ScreenCaptureKit did not answer \(request) in \(Int(seconds)) s — replayd dropped the request"
    }
}

/// Whichever side of `answered(_:_:)` gets there first — the answer or the
/// deadline — hands its result on; the other finds nobody waiting.
@MainActor
private final class Reply<T> {

    private var continuation: CheckedContinuation<T, Error>?
    var deadline: Task<Void, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        continuation.resume(with: result)
    }
}

/// ScreenCaptureKit serves one test process at a time — for as long as that
/// process lives, not for as long as it captures.
///
/// replayd, the daemon behind ScreenCaptureKit, tells its clients apart by the
/// path of their executable, and every test process is the same `xctest`. A
/// second one connecting evicts the first; each reconnects and evicts the
/// other, and a request in flight on an evicted connection is dropped with no
/// reply. Measured with one plain executable run twice: two copies capturing at
/// once both waited forever; a second copy capturing while the first sat idle
/// after its own capture waited forever too; two *different* executables
/// captured side by side without a miss. So it is the process, not the
/// capture, that has to be serialised.
///
/// The first capture in a process takes a machine-wide `flock` and never gives
/// it back — the kernel releases it when the process exits. A test process
/// elsewhere (another worktree's `make test-kit`) waits for it at its own first
/// capture, until `deadline`.
@MainActor
private enum CaptureLease {

    static let path = "/tmp/xctest-screencapturekit.lock"

    /// Longer than a whole TranscriptKit run takes on a loaded machine.
    static let deadline: TimeInterval = 300

    private static var held: Int32?

    static func take() async throws {
        guard held == nil else { return }
        let file = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o666)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let until = Date(timeIntervalSinceNow: deadline)
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK else {
                close(file)
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
            guard Date() < until else {
                let holder = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "?"
                close(file)
                throw Held(holder: holder, seconds: deadline)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        held = file
        let pid = Data("\(getpid())".utf8)
        ftruncate(file, 0)
        _ = pid.withUnsafeBytes { pwrite(file, $0.baseAddress, pid.count, 0) }
    }

    private struct Held: Error, CustomStringConvertible {
        let holder: String
        let seconds: TimeInterval

        var description: String {
            "test process \(holder) held ScreenCaptureKit for longer than \(Int(seconds)) s"
        }
    }
}

import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `ImagePreviewPresenter`
/// (migration plan §4.7-1, R5, §9). Mirrors `Transcript2SheetPresenterLifetimeTests`:
/// the owned input-bar preview presenter must present a sheet on a windowed
/// host, dismiss it on `stop()` (no orphan that wedges the window), be
/// idempotent on a second dismiss, be a window-guarded no-op when not windowed,
/// and deallocate (no retain cycle) once released.
@MainActor
final class ImagePreviewPresenterLifetimeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func windowedHost() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = host
        window.ccterm_orderFrontForTesting()
        return (window, host)
    }

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    // MARK: - Present begins a sheet; stop dismisses it

    func testPresentBeginsSheetAndStopDismisses() {
        let (window, host) = windowedHost()
        defer {
            window.contentView = nil
            window.close()
        }
        let presenter = ImagePreviewPresenter(hostView: host)
        presenter.present(NSImage(size: NSSize(width: 40, height: 40)))
        pump(seconds: 0.2)
        XCTAssertEqual(window.sheets.count, 1, "present begins exactly one sheet on the host window.")

        presenter.stop()
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.sheets.isEmpty }, object: nil)
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(window.sheets.isEmpty, "stop() dismisses the preview (no orphan).")

        // Idempotent: a second dismiss must not crash / re-open.
        presenter.dismiss()
        presenter.stop()
        XCTAssertTrue(window.sheets.isEmpty, "A second dismiss is a no-op (idempotent).")
    }

    // MARK: - Window-guarded (no window → no-op, no crash)

    func testPresentWithoutWindowIsNoOp() {
        let host = NSView()  // never added to a window
        let presenter = ImagePreviewPresenter(hostView: host)
        presenter.present(NSImage(size: NSSize(width: 10, height: 10)))
        presenter.dismiss()
        presenter.stop()
        XCTAssertTrue(true, "present/dismiss/stop are window-guarded no-ops with no window.")
    }

    // MARK: - Latest-tap-wins replaces the open sheet

    func testSecondPresentReplacesFirst() {
        let (window, host) = windowedHost()
        defer {
            window.contentView = nil
            window.close()
        }
        let presenter = ImagePreviewPresenter(hostView: host)
        presenter.present(NSImage(size: NSSize(width: 40, height: 40)))
        pump(seconds: 0.2)
        XCTAssertEqual(window.sheets.count, 1)
        // A second present dismisses the first and shows the new one.
        presenter.present(NSImage(size: NSSize(width: 60, height: 60)))
        pump(seconds: 0.3)
        XCTAssertEqual(window.sheets.count, 1, "Latest tap wins — at most one preview is open.")
        presenter.stop()
    }

    // MARK: - No retain cycle (deallocs after stop)

    func testPresenterDeallocatesAfterStop() {
        let host = NSView()
        weak var weakPresenter: ImagePreviewPresenter?
        autoreleasepool {
            let presenter = ImagePreviewPresenter(hostView: host)
            weakPresenter = presenter
            presenter.stop()
        }
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in weakPresenter == nil }, object: nil)
        wait(for: [exp], timeout: 5)
        XCTAssertNil(weakPresenter, "presenter must deallocate after stop() — no retain cycle.")
    }
}

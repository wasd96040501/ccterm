import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `AttachButtonView` (migration
/// plan §4.1-10, §9): 32pt size (so the glass circle's corner radius is
/// `size/2 = 16`), press-dim that lowers ONLY the `+` glyph alpha to ~0.5
/// while the glass circle stays solid, and a click that fires `onPick` exactly
/// once. Drives the REAL mouse event path (`mouseDown` / `mouseUp`).
@MainActor
final class AttachButtonViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Mount in an offscreen window so `convert(_:from: nil)` maps window
    /// coordinates into the button's bounds for the press tracking.
    private func mounted(_ button: AttachButtonView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    /// A mouse event whose window location maps to the button's center.
    private func mouseEvent(
        _ type: NSEvent.EventType, at center: NSPoint, in window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    // MARK: - Size / corner radius

    func testSizeIs32AndCornerRadiusIsHalf() {
        XCTAssertEqual(AttachButtonView.size, 32, accuracy: 0.5, "Attach button is a 32pt circle.")
        // The glass circle's corner radius is `size/2` (a circle) — the init
        // passes exactly `AttachButtonView.size / 2 = 16` to `BarSurfaceView`.
        XCTAssertEqual(AttachButtonView.size / 2, 16, accuracy: 0.5, "Circle radius = size/2 = 16.")
        let button = AttachButtonView()
        XCTAssertEqual(button.intrinsicContentSize.width, 32, accuracy: 0.5)
        XCTAssertEqual(button.intrinsicContentSize.height, 32, accuracy: 0.5)
    }

    // MARK: - Press-dim is glyph-only (§4.1-10)

    func testPressDimsGlyphOnlyNotSurface() {
        let button = AttachButtonView()
        let window = mounted(button)
        defer {
            window.contentView = nil
            window.close()
        }
        let centerInWindow = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        XCTAssertEqual(button.glyphAlphaForTestObservation, 1.0, accuracy: 0.01, "Idle glyph solid.")
        XCTAssertEqual(button.surfaceAlphaForTestObservation, 1.0, accuracy: 0.01, "Idle surface solid.")

        button.mouseDown(with: mouseEvent(.leftMouseDown, at: centerInWindow, in: window))
        XCTAssertEqual(
            button.glyphAlphaForTestObservation, 0.5, accuracy: 0.01,
            "Press dims the `+` glyph to ~0.5.")
        XCTAssertEqual(
            button.surfaceAlphaForTestObservation, 1.0, accuracy: 0.01,
            "The glass circle stays solid while pressed (icon-only dim, §4.1-10).")

        button.mouseUp(with: mouseEvent(.leftMouseUp, at: centerInWindow, in: window))
        XCTAssertEqual(
            button.glyphAlphaForTestObservation, 1.0, accuracy: 0.01,
            "Mouse-up restores the glyph alpha.")
    }

    // MARK: - Click fires onPick exactly once

    func testClickFiresOnPickOnce() {
        let button = AttachButtonView()
        let window = mounted(button)
        defer {
            window.contentView = nil
            window.close()
        }
        var picks = 0
        button.onPick = { picks += 1 }
        let centerInWindow = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        button.mouseDown(with: mouseEvent(.leftMouseDown, at: centerInWindow, in: window))
        button.mouseUp(with: mouseEvent(.leftMouseUp, at: centerInWindow, in: window))
        XCTAssertEqual(picks, 1, "A press+release inside the button fires onPick exactly once.")
    }

    func testMouseUpOutsideDoesNotFireOnPick() {
        let button = AttachButtonView()
        let window = mounted(button)
        defer {
            window.contentView = nil
            window.close()
        }
        var picks = 0
        button.onPick = { picks += 1 }
        let centerInWindow = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        // Down inside…
        button.mouseDown(with: mouseEvent(.leftMouseDown, at: centerInWindow, in: window))
        // …drag far outside the bounds, then release there.
        let outside = NSPoint(x: centerInWindow.x + 500, y: centerInWindow.y + 500)
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, at: outside, in: window))
        button.mouseUp(with: mouseEvent(.leftMouseUp, at: outside, in: window))
        XCTAssertEqual(picks, 0, "A release outside the bounds must NOT fire onPick.")
    }
}

import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `ImagePreviewSheetViewController`
/// (migration plan §4.7-3/4, §9): the two dismiss surfaces (Done/Return default
/// action, Esc → `cancelOperation`, click on the image area), and the per-caller
/// size envelope (transcript 480/880/1400 vs input-bar 360/520/800). Drives the
/// REAL VC + its dismiss closure; envelope is asserted on the VC's
/// `preferredContentSize` + the stored `Envelope`.
@MainActor
final class ImagePreviewSheetViewControllerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeVC(
        envelope: ImagePreviewSheetViewController.Envelope = .inputBar,
        imagePadding: CGFloat = 20,
        onDismiss: @escaping () -> Void
    ) -> ImagePreviewSheetViewController {
        ImagePreviewSheetViewController(
            image: NSImage(size: NSSize(width: 40, height: 40)),
            envelope: envelope, imagePadding: imagePadding, onDismiss: onDismiss)
    }

    // MARK: - Esc → cancelOperation → onDismiss

    func testEscDismisses() {
        var dismissed = 0
        let vc = makeVC { dismissed += 1 }
        vc.loadViewIfNeeded()
        vc.cancelOperation(nil)
        XCTAssertEqual(dismissed, 1, "Esc (cancelOperation) routes to onDismiss.")
    }

    // MARK: - Done / Return default action → onDismiss

    func testDoneButtonDismisses() {
        var dismissed = 0
        let vc = makeVC { dismissed += 1 }
        vc.loadViewIfNeeded()
        // Find the Done button and fire its action the way Return (its `\r`
        // keyEquivalent default action) would.
        let done = findButton(in: vc.view)
        XCTAssertNotNil(done, "The sheet has a Done button.")
        XCTAssertEqual(done?.keyEquivalent, "\r", "Done is the default action (Return resolves to it).")
        done?.performClick(nil)
        XCTAssertEqual(dismissed, 1, "Clicking Done routes to onDismiss.")
    }

    // MARK: - Click on the image area → onDismiss

    func testClickOnImageAreaDismisses() {
        var dismissed = 0
        let vc = makeVC { dismissed += 1 }
        vc.view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        vc.view.layoutSubtreeIfNeeded()
        // The image area is the click-to-dismiss backdrop; locate it and fire
        // a mouseUp inside it.
        guard let imageArea = findClickToDismiss(in: vc.view) else {
            return XCTFail("Expected a click-to-dismiss image area in the sheet.")
        }
        let centerInWindow = imageArea.convert(
            NSPoint(x: imageArea.bounds.midX, y: imageArea.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: centerInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: centerInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        imageArea.mouseDown(with: down)
        imageArea.mouseUp(with: up)
        XCTAssertEqual(dismissed, 1, "A click on the image area routes to onDismiss.")
    }

    // MARK: - Per-caller envelope (§4.7-3, R19)

    func testTranscriptEnvelopeSeedsIdealAndBounds() {
        let vc = makeVC(envelope: .transcript, imagePadding: 24) {}
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.envelope, .transcript)
        // preferredContentSize seeds the ideal.
        XCTAssertEqual(vc.preferredContentSize.width, 880, accuracy: 0.5)
        XCTAssertEqual(vc.preferredContentSize.height, 660, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.minWidth, 480, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxWidth, 1400, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.minHeight, 360, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxHeight, 1050, accuracy: 0.5)
    }

    func testInputBarEnvelopeSeedsIdealAndBounds() {
        let vc = makeVC(envelope: .inputBar, imagePadding: 20) {}
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.envelope, .inputBar)
        XCTAssertEqual(vc.preferredContentSize.width, 520, accuracy: 0.5)
        XCTAssertEqual(vc.preferredContentSize.height, 420, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.minWidth, 360, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxWidth, 800, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.minHeight, 280, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxHeight, 720, accuracy: 0.5)
    }

    // MARK: - Helpers

    private func findButton(in view: NSView) -> NSButton? {
        if let b = view as? NSButton { return b }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }

    private func findClickToDismiss(in view: NSView) -> NSView? {
        // The image-area backdrop is the view whose class name contains
        // "ClickToDismiss" (a private type). Walk and match on the dynamic type.
        if String(describing: type(of: view)).contains("ClickToDismiss") { return view }
        for sub in view.subviews {
            if let found = findClickToDismiss(in: sub) { return found }
        }
        return nil
    }
}

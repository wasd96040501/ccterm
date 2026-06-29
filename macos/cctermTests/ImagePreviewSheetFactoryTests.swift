import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the transcript image-preview
/// sheet body (`ImagePreviewSheetFactory`, migration plan §4.7). The transcript
/// path does NOT introduce a second preview view — it routes to the shared
/// `ImagePreviewSheetViewController` (Phase 1) with the wider transcript
/// envelope. These tests drive the REAL VC built through the seam and assert
/// observable behavior:
///
/// - the exact `NSImage` handed in is the one the `NSImageView` shows
///   (`imageView.image === image`, aspect-FIT scaling),
/// - the transcript envelope (480 / 880 / 1400 × 360 / 660 / 1050) + padding
///   (24) — the wider one, NOT the input bar's `.inputBar`,
/// - all three dismiss surfaces route to the injected `onDismiss`: the Done
///   button (Return default action, keyEquivalent `\r`), Esc
///   (`cancelOperation`), and a click on the image area.
@MainActor
final class ImagePreviewSheetFactoryTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - The handed-in image is what the VC shows (aspect-fit)

    func testTranscriptVCShowsTheExactImage() {
        let image = NSImage(size: NSSize(width: 120, height: 80))
        let vc = ImagePreviewSheetFactory.makeTranscriptViewController(image: image) {}
        vc.loadViewIfNeeded()

        guard let imageView = findImageView(in: vc.view) else {
            return XCTFail("Expected an NSImageView in the transcript image-preview body.")
        }
        XCTAssertTrue(
            imageView.image === image,
            "The body shows the exact NSImage handed in (no copy / re-decode).")
        XCTAssertEqual(
            imageView.imageScaling, .scaleProportionallyUpOrDown,
            "Aspect-FIT scaling, matching the SwiftUI .aspectRatio(contentMode: .fit).")
    }

    // MARK: - Transcript envelope + padding (the wider one, NOT input-bar)

    func testTranscriptEnvelopeAndPadding() {
        let vc = ImagePreviewSheetFactory.makeTranscriptViewController(
            image: NSImage(size: NSSize(width: 40, height: 40))
        ) {}
        vc.loadViewIfNeeded()

        XCTAssertEqual(
            vc.envelope, .transcript,
            "Transcript path uses the wider transcript envelope, not .inputBar.")
        XCTAssertEqual(ImagePreviewSheetFactory.envelope, .transcript)
        XCTAssertEqual(ImagePreviewSheetFactory.imagePadding, 24, accuracy: 0.5)

        // Verbatim from ImagePreviewSheetView.swift:35-37.
        XCTAssertEqual(vc.envelope.minWidth, 480, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.idealWidth, 880, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxWidth, 1400, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.minHeight, 360, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.idealHeight, 660, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxHeight, 1050, accuracy: 0.5)

        // preferredContentSize seeds the ideal content size for the sheet window.
        XCTAssertEqual(vc.preferredContentSize.width, 880, accuracy: 0.5)
        XCTAssertEqual(vc.preferredContentSize.height, 660, accuracy: 0.5)

        // The transcript envelope is strictly wider than the input bar's — a
        // regression that re-used .inputBar would shrink the full-text preview.
        XCTAssertGreaterThan(
            vc.envelope.idealWidth,
            ImagePreviewSheetViewController.Envelope.inputBar.idealWidth,
            "Transcript preview is larger than the input-bar attachment preview.")
    }

    // MARK: - The 24pt seam constant is actually applied as the image inset

    /// Gate-load-bearing end-to-end: the seam's `imagePadding == 24` must reach
    /// the built VC's image-area inset, not just be a static constant. Lay the
    /// VC out at the transcript ideal width and assert the `NSImageView` insets
    /// ~24pt from its click-to-dismiss container on every edge — so a future
    /// refactor that dropped the padding wiring in `makeTranscriptViewController`
    /// (or hard-coded a different inset) fails here, not silently passes.
    func testTranscriptImageInsetIsAppliedAt24() {
        let vc = ImagePreviewSheetFactory.makeTranscriptViewController(
            image: NSImage(size: NSSize(width: 200, height: 200))
        ) {}
        vc.view.frame = NSRect(x: 0, y: 0, width: 880, height: 660)
        vc.view.layoutSubtreeIfNeeded()

        guard let imageArea = findClickToDismiss(in: vc.view),
            let imageView = findImageView(in: vc.view)
        else {
            return XCTFail("Expected the image area + image view in the body.")
        }
        // imageView is a subview of imageArea; its frame insets by imagePadding
        // on each edge (constraints at ImagePreviewSheetViewController.swift).
        let f = imageView.frame
        let area = imageArea.bounds
        XCTAssertEqual(f.minX, 24, accuracy: 0.5, "Leading inset == imagePadding (24).")
        XCTAssertEqual(f.minY, 24, accuracy: 0.5, "Bottom inset == imagePadding (24).")
        XCTAssertEqual(area.maxX - f.maxX, 24, accuracy: 0.5, "Trailing inset == 24.")
        XCTAssertEqual(area.maxY - f.maxY, 24, accuracy: 0.5, "Top inset == 24.")
    }

    // MARK: - Done button (Return default action) → onDismiss

    func testDoneButtonDismisses() {
        var dismissed = 0
        let vc = ImagePreviewSheetFactory.makeTranscriptViewController(
            image: NSImage(size: NSSize(width: 40, height: 40))
        ) { dismissed += 1 }
        vc.loadViewIfNeeded()

        guard let done = findButton(in: vc.view) else {
            return XCTFail("Expected a Done button in the transcript image-preview body.")
        }
        XCTAssertEqual(
            done.title, String(localized: "Done"), "The button copy is the localized \"Done\".")
        XCTAssertEqual(
            done.keyEquivalent, "\r",
            "Done is the default action so Return resolves to it (§4.7-4).")
        done.performClick(nil)
        XCTAssertEqual(dismissed, 1, "Clicking Done (or Return) routes to onDismiss.")
    }

    // MARK: - Esc → cancelOperation → onDismiss

    func testEscDismisses() {
        var dismissed = 0
        let vc = ImagePreviewSheetFactory.makeTranscriptViewController(
            image: NSImage(size: NSSize(width: 40, height: 40))
        ) { dismissed += 1 }
        vc.loadViewIfNeeded()
        vc.cancelOperation(nil)
        XCTAssertEqual(dismissed, 1, "Esc (cancelOperation) routes to onDismiss.")
    }

    // MARK: - Click on the image area → onDismiss

    func testClickOnImageAreaDismisses() {
        var dismissed = 0
        let vc = ImagePreviewSheetFactory.makeTranscriptViewController(
            image: NSImage(size: NSSize(width: 40, height: 40))
        ) { dismissed += 1 }
        // Size at the transcript ideal so the image area has real bounds.
        vc.view.frame = NSRect(x: 0, y: 0, width: 880, height: 660)
        vc.view.layoutSubtreeIfNeeded()

        guard let imageArea = findClickToDismiss(in: vc.view) else {
            return XCTFail("Expected a click-to-dismiss image area in the body.")
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

    // MARK: - Helpers

    private func findImageView(in view: NSView) -> NSImageView? {
        if let v = view as? NSImageView { return v }
        for sub in view.subviews {
            if let found = findImageView(in: sub) { return found }
        }
        return nil
    }

    private func findButton(in view: NSView) -> NSButton? {
        if let b = view as? NSButton { return b }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }

    private func findClickToDismiss(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("ClickToDismiss") { return view }
        for sub in view.subviews {
            if let found = findClickToDismiss(in: sub) { return found }
        }
        return nil
    }
}

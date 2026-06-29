import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `UserBubbleSheetViewController`
/// (migration plan §4.7, §9): drives the REAL production VC + its dismiss
/// closure. Asserts the full bubble text is shown in a read-only but
/// SELECTABLE `NSTextView` (so ⌘C still works, matching SwiftUI
/// `.textSelection(.enabled)`), that the Done button (default action / Return)
/// and Esc (`cancelOperation`) and a Return reaching the text view all route to
/// `onDismiss`, and that the size envelope seeds `preferredContentSize` +
/// bounds.
@MainActor
final class UserBubbleSheetBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private let sampleText = "Hello world.\nThis is the full user bubble text that the sheet shows."

    private func makeVC(
        text: String,
        onDismiss: @escaping () -> Void
    ) -> UserBubbleSheetViewController {
        UserBubbleSheetViewController(text: text, onDismiss: onDismiss)
    }

    // MARK: - Text is shown in a selectable, non-editable text view

    func testFullTextIsShown() {
        let vc = makeVC(text: sampleText) {}
        vc.loadViewIfNeeded()
        guard let tv = findTextView(in: vc.view) else {
            return XCTFail("Expected an NSTextView showing the bubble text.")
        }
        XCTAssertEqual(tv.string, sampleText, "The text view shows the full bubble text verbatim.")
    }

    func testTextViewIsSelectableButNotEditable() {
        let vc = makeVC(text: sampleText) {}
        vc.loadViewIfNeeded()
        guard let tv = findTextView(in: vc.view) else {
            return XCTFail("Expected an NSTextView in the sheet.")
        }
        // Matches SwiftUI `.textSelection(.enabled)` on read-only Text: ⌘C
        // copies, but no typing edits.
        XCTAssertTrue(tv.isSelectable, "The text view is selectable so ⌘C copy works.")
        XCTAssertFalse(tv.isEditable, "The text view is read-only (non-editable).")
    }

    // MARK: - Done / Return default action → onDismiss

    func testDoneButtonDismisses() {
        var dismissed = 0
        let vc = makeVC(text: sampleText) { dismissed += 1 }
        vc.loadViewIfNeeded()
        let done = findButton(in: vc.view)
        XCTAssertNotNil(done, "The sheet has a Done button.")
        XCTAssertEqual(done?.keyEquivalent, "\r", "Done is the default action (Return resolves to it).")
        done?.performClick(nil)
        XCTAssertEqual(dismissed, 1, "Clicking Done routes to onDismiss.")
    }

    // MARK: - Esc → cancelOperation → onDismiss

    func testEscDismisses() {
        var dismissed = 0
        let vc = makeVC(text: sampleText) { dismissed += 1 }
        vc.loadViewIfNeeded()
        vc.cancelOperation(nil)
        XCTAssertEqual(dismissed, 1, "Esc (cancelOperation) routes to onDismiss.")
    }

    // MARK: - Return reaching the selectable text view forwards to onDismiss

    func testReturnInTextViewDismisses() {
        var dismissed = 0
        let vc = makeVC(text: sampleText) { dismissed += 1 }
        vc.loadViewIfNeeded()
        guard let tv = findTextView(in: vc.view) else {
            return XCTFail("Expected an NSTextView in the sheet.")
        }
        // A read-only selectable text view that became first responder would
        // otherwise swallow Return; the VC forwards insertNewline → onDismiss
        // so Return still dismisses (§4.7-2).
        tv.insertNewline(nil)
        XCTAssertEqual(dismissed, 1, "Return reaching the text view routes to onDismiss.")
    }

    // MARK: - Envelope (§4.7-3)

    func testEnvelopeSeedsIdealAndBounds() {
        let vc = makeVC(text: sampleText) {}
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.envelope, .userBubble)
        // preferredContentSize seeds the ideal.
        XCTAssertEqual(vc.preferredContentSize.width, 720, accuracy: 0.5)
        XCTAssertEqual(vc.preferredContentSize.height, 540, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.minWidth, 520, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxWidth, 960, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.minHeight, 360, accuracy: 0.5)
        XCTAssertEqual(vc.envelope.maxHeight, 800, accuracy: 0.5)
    }

    // MARK: - Helpers

    private func findButton(in view: NSView) -> NSButton? {
        if let b = view as? NSButton { return b }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }
}

import AppKit
import XCTest

@testable import ccterm

/// What the composer reports, driven through its buttons.
@MainActor
final class ComposerViewTests: XCTestCase {
    private final class Recorder: ComposerViewDelegate {
        var submitted: [String] = []
        var stops = 0
        func composerView(_ composerView: ComposerView, didSubmit text: String) { submitted.append(text) }
        func composerViewDidRequestStop(_ composerView: ComposerView) { stops += 1 }
    }

    private var composer: ComposerView!
    private var recorder: Recorder!
    private var window: NSWindow!

    override func setUp() {
        composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        recorder = Recorder()
        composer.delegate = recorder
        window = NSWindow(contentRect: composer.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = composer
        composer.layoutSubtreeIfNeeded()
    }

    private func find<V: NSView>(_ type: V.Type, in view: NSView, where match: (V) -> Bool = { _ in true }) -> V? {
        if let found = view as? V, match(found) { return found }
        for subview in view.subviews {
            if let found = find(type, in: subview, where: match) { return found }
        }
        return nil
    }

    private func button(_ title: String) -> NSButton? {
        find(NSButton.self, in: composer) { $0.accessibilityLabel() == title }
    }

    private func textView() -> NSTextView? {
        find(NSTextView.self, in: composer)
    }

    func testSendNeedsWordsAndReportsThemTrimmedAndClearsTheField() throws {
        let send = try XCTUnwrap(button(String(localized: "Send")))
        XCTAssertFalse(send.isEnabled)
        composer.showFailure("x", of: "  hello \n")
        XCTAssertTrue(send.isEnabled)
        send.performClick(nil)
        XCTAssertEqual(recorder.submitted, ["hello"])
        XCTAssertEqual(try XCTUnwrap(textView()).string, "")
        XCTAssertFalse(send.isEnabled)
    }

    func testAFailedSendPutsTheWordsBackUnlessTheReaderHasWrittenSomethingElse() throws {
        composer.showFailure("Couldn’t send", of: "first")
        XCTAssertEqual(try XCTUnwrap(textView()).string, "first")
        composer.showFailure("Couldn’t send", of: "second")
        XCTAssertEqual(try XCTUnwrap(textView()).string, "first")
    }

    func testWhileATurnRunsTheButtonIsStopAndIdempotent() throws {
        let send = try XCTUnwrap(button(String(localized: "Send")))
        let stop = try XCTUnwrap(button(String(localized: "Stop")))
        XCTAssertTrue(stop.isHidden)
        composer.configure(isResponding: true)
        composer.configure(isResponding: true)
        XCTAssertTrue(send.isHidden)
        XCTAssertFalse(stop.isHidden)
        stop.performClick(nil)
        XCTAssertEqual(recorder.stops, 1)
        composer.configure(isResponding: false)
        XCTAssertFalse(send.isHidden)
        XCTAssertTrue(stop.isHidden)
    }

    func testTheFieldGrowsWithItsTextUpToACap() throws {
        composer.showFailure("x", of: "one")
        composer.layoutSubtreeIfNeeded()
        let one = composer.fittingSize.height
        let text = try XCTUnwrap(textView())
        text.string = (1...30).map { "line \($0)" }.joined(separator: "\n")
        text.didChangeText()
        composer.layoutSubtreeIfNeeded()
        let many = composer.fittingSize.height
        XCTAssertGreaterThan(many, one + 40)
        XCTAssertLessThanOrEqual(many, one + 160)
    }
}

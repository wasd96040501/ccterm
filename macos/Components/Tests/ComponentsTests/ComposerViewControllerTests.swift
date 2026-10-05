import AppKit
import DisplayModels
import XCTest

@testable import Components
@testable import ComponentsDesign

/// What the composer reports, driven the way its controls are: the keys go
/// through the field's command selectors, the buttons through `performClick`,
/// the menus through the items they build.
@MainActor
final class ComposerViewControllerTests: XCTestCase {
    private typealias F = ComposerFixtures

    private final class Recorder: ComposerViewControllerDelegate {
        var submitted: [String] = []
        var stops = 0
        var chosen: [String] = []
        var fast: [Bool] = []
        var restarts = 0
        var logs = 0
        var waiting = 0
        var contexts = 0
        func composerViewController(_ c: ComposerViewController, didSubmit text: String) { submitted.append(text) }
        func composerViewControllerDidRequestStop(_ c: ComposerViewController) { stops += 1 }
        func composerViewController(_ c: ComposerViewController, didChoose id: String) { chosen.append(id) }
        func composerViewController(_ c: ComposerViewController, didSetFastMode isOn: Bool) { fast.append(isOn) }
        func composerViewControllerDidRequestRestart(_ c: ComposerViewController) { restarts += 1 }
        func composerViewControllerDidRequestLog(_ c: ComposerViewController) { logs += 1 }
        func composerViewControllerDidRequestWaitingRequest(_ c: ComposerViewController) { waiting += 1 }
        func composerViewControllerDidRequestContextUsage(_ c: ComposerViewController) { contexts += 1 }
    }

    private var composer: ComposerViewController!
    private var recorder: Recorder!
    private var window: NSWindow!

    override func setUp() {
        composer = ComposerViewController()
        recorder = Recorder()
        composer.delegate = recorder
        window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 760, height: 300), styleMask: [.borderless],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = root
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(composer.view)
        NSLayoutConstraint.activate([
            composer.view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            composer.view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            composer.view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        configure(F.idle)
        window.layoutIfNeeded()
    }

    override func tearDown() {
        window.close()
    }

    private func configure(_ model: ComposerPresentation) {
        composer.configure(with: model)
        composer.view.layoutSubtreeIfNeeded()
    }

    private func find<V: NSView>(_ type: V.Type, where match: (V) -> Bool = { _ in true }) -> V? {
        func walk(_ view: NSView) -> V? {
            if let found = view as? V, match(found) { return found }
            for subview in view.subviews { if let found = walk(subview) { return found } }
            return nil
        }
        return walk(composer.view)
    }

    private func textView() throws -> NSTextView { try XCTUnwrap(find(NSTextView.self)) }

    /// Presses a key the way the text view reports it.
    @discardableResult
    private func press(_ selector: Selector) throws -> Bool {
        let view = try textView()
        return (view.delegate as? NSTextViewDelegate)?.textView?(view, doCommandBy: selector) ?? false
    }

    private func type(_ text: String) throws {
        let view = try textView()
        view.string = text
        (view.delegate as? NSTextViewDelegate)?.textDidChange?(Notification(name: NSText.didChangeNotification))
    }

    private func actionButton(_ kind: ComposerActionButton.Kind) -> ComposerActionButton? {
        find(ComposerActionButton.self) { $0.kind == kind }
    }

    /// The failure section's two buttons, Show Log then Restart.
    private func failureButtons() -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, button.target is ComposerFailureView { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(composer.view)
        return found
    }

    // MARK: Sending

    func testReturnSendsTheWordsTrimmedAndClearsTheField() throws {
        try type("  hello \n")
        XCTAssertTrue(try press(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(recorder.submitted, ["hello"])
        XCTAssertEqual(composer.text, "")
    }

    func testReturnWithNothingToSendSendsNothingAndKeepsTheKey() throws {
        XCTAssertTrue(try press(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(recorder.submitted, [])
    }

    func testTheArrowIsDisabledUntilThereAreWordsAndSendsThem() throws {
        let send = try XCTUnwrap(actionButton(.send))
        XCTAssertFalse(send.isEnabled)
        try type("run it")
        XCTAssertTrue(send.isEnabled)
        send.performClick(nil)
        XCTAssertEqual(recorder.submitted, ["run it"])
        XCTAssertFalse(send.isEnabled)
    }

    func testWhileClaudeWorksStopIsShownAndTheArrowAppearsWithWords() throws {
        configure(F.responding)
        let stop = try XCTUnwrap(actionButton(.stop))
        let send = try XCTUnwrap(actionButton(.send))
        XCTAssertFalse(stop.isHidden)
        XCTAssertTrue(send.isHidden)
        try type("and the docs")
        XCTAssertFalse(send.isHidden)
        stop.performClick(nil)
        XCTAssertEqual(recorder.stops, 1)
    }

    // MARK: Words and the token

    func testACommandAtTheStartBecomesTheTokenAndComesBackAsItsText() {
        composer.text = "/review #327"
        XCTAssertEqual(composer.text, "/review #327")
        composer.text = "/unknown thing"
        XCTAssertEqual(composer.text, "/unknown thing")
    }

    func testBackspaceIntoTheTokenRemovesItWhole() throws {
        composer.text = "/review"
        XCTAssertEqual(composer.text, "/review")
        XCTAssertTrue(try press(#selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(composer.text, "")
        XCTAssertFalse(try press(#selector(NSResponder.deleteBackward(_:))))
    }

    /// Typing is undoable; words set from outside (a send clears the field)
    /// leave nothing to undo, so ⌘Z never replays edits against them.
    func testSetWordsLeaveNothingToUndo() throws {
        let view = try textView()
        view.insertText("hello", replacementRange: view.selectedRange())
        XCTAssertEqual(view.undoManager?.canUndo, true)
        composer.text = ""
        XCTAssertEqual(view.undoManager?.canUndo, false)
    }

    func testATokenAloneCanBeSent() throws {
        composer.text = "/context"
        XCTAssertTrue(try press(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(recorder.submitted, ["/context"])
    }

    func testTheFieldGrowsWithItsWordsAndStopsAtEightLines() throws {
        let before = composer.fittedHeight
        composer.text = (1...3).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(composer.fittedHeight - before, 44, accuracy: 2)
        composer.text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        composer.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(composer.fittedHeight - before, 22 * 7, accuracy: 2)
    }

    // MARK: Keys

    func testShiftTabChoosesTheNextMode() throws {
        XCTAssertEqual(F.idle.cycledModeID, "mode:acceptEdits", "premise: the fixture's cycle")
        XCTAssertTrue(try press(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(recorder.chosen, ["mode:acceptEdits"])
    }

    func testShiftTabIsSwallowedWhenThereIsNothingToChoose() throws {
        configure(F.loading)
        XCTAssertNil(F.loading.cycledModeID)
        XCTAssertTrue(try press(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(recorder.chosen, [])
    }

    /// With no slash list open, ⎋ goes up the responder chain (the permission
    /// card, a sheet) and stops nothing.
    func testEscapeGoesUpTheResponderChain() throws {
        configure(F.responding)
        let above = CancelRecorder()
        above.nextResponder = composer.nextResponder
        composer.nextResponder = above
        XCTAssertTrue(try press(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(above.cancels, 1)
        XCTAssertEqual(recorder.stops, 0)
    }

    // MARK: Slash commands

    func testTypingASlashCompletesACommandIntoTheToken() throws {
        try type("/rev")
        // ⇥ with the list over the field completes the selected command.
        XCTAssertTrue(try press(#selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(composer.text, "/review")
        try type("#12")
        XCTAssertEqual(composer.text, "/review #12")
    }

    func testReturnWithTheListOpenCompletesInsteadOfSending() throws {
        try type("/co")
        XCTAssertTrue(try press(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(recorder.submitted, [])
        XCTAssertEqual(composer.text, "/compact")
    }

    func testASpaceEndsCompletionSoTypedOutCommandsStayPlainText() throws {
        try type("/model sonnet")
        XCTAssertTrue(try press(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(recorder.submitted, ["/model sonnet"])
    }

    // MARK: Failure, status, ring

    func testTheFailureSectionsButtonsReportRestartAndLog() throws {
        configure(F.failed)
        let buttons = failureButtons()
        XCTAssertEqual(buttons.count, 2)
        buttons[1].performClick(nil)
        buttons[0].performClick(nil)
        XCTAssertEqual(recorder.restarts, 1)
        XCTAssertEqual(recorder.logs, 1)
    }

    func testTheContextRingOpensTheContext() throws {
        configure(F.fastRing)
        let ring = try XCTUnwrap(find(ContextRingButton.self))
        XCTAssertFalse(ring.isHidden)
        ring.performClick(nil)
        XCTAssertEqual(recorder.contexts, 1)
        configure(F.state(ring: nil))
        XCTAssertTrue(ring.isHidden)
    }

    func testWaitingForYouShowsTheRequest() throws {
        configure(F.waiting)
        let button = try XCTUnwrap(find(NSButton.self) { $0.title == "Waiting for you ↑" && !$0.isHidden })
        button.performClick(nil)
        XCTAssertEqual(recorder.waiting, 1)
    }

    // MARK: - Narrow

    /// The status's words never set the card's width: in a window sized to
    /// 330 pt the card stays 330 wide and its status moves under the controls.
    func testANarrowCardIsTheWidthItIsGivenWithTheStatusUnderTheControls() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 330, height: 200), styleMask: [.borderless],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Shown, then pinned edge to edge in a view, as a tab holds its composer.
        let narrow = ComposerViewController()
        narrow.configure(with: F.atRest)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 200))
        window.contentView = root
        narrow.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(narrow.view)
        NSLayoutConstraint.activate([
            narrow.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            narrow.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            narrow.view.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        window.setContentSize(NSSize(width: 330, height: 200))
        // Ordered in (off screen) and displayed: the window's own pass, where
        // content above `.windowSizeStayPut` would grow it.
        window.orderFrontRegardless()
        window.displayIfNeeded()

        XCTAssertEqual(window.frame.width, 330, "the composer widened its window")
        XCTAssertEqual(narrow.view.frame.width, 330)
        func find<V: NSView>(_ type: V.Type, in view: NSView, where match: (V) -> Bool) -> V? {
            if let found = view as? V, match(found) { return found }
            for subview in view.subviews { if let found = find(type, in: subview, where: match) { return found } }
            return nil
        }
        let status = try XCTUnwrap(
            find(NSTextField.self, in: narrow.view) { $0.stringValue == "Will resume when you send" }
        )
        let send = try XCTUnwrap(
            find(ComposerActionButton.self, in: narrow.view) { $0.kind == .send })
        let statusFrame = status.convert(status.bounds, to: nil)
        let sendFrame = send.convert(send.bounds, to: nil)
        XCTAssertLessThan(statusFrame.maxY, sendFrame.minY + 0.5, "the status is not under the controls")
        XCTAssertLessThanOrEqual(statusFrame.maxX, 330, "the status runs out of the card")
    }

    // MARK: - Menus

    /// A menu button opens its menu and is on while it is open; the next
    /// press on it closes the menu, a press on another moves it there.
    func testAMenuButtonOpensItsMenuAndTheNextPressClosesIt() throws {
        func popoverIsOpen() -> Bool {
            NSApp.windows.contains { $0.isVisible && String(describing: Swift.type(of: $0)).contains("Popover") }
        }
        // A popover opens only from a window on screen (this one is far off it).
        window.orderFrontRegardless()
        let model = try XCTUnwrap(find(MenuButton.self) { $0.attributedTitle.string.hasPrefix("Sonnet") })
        let effort = try XCTUnwrap(find(MenuButton.self) { $0 !== model })
        model.performClick(nil)
        XCTAssertEqual(model.state, .on)
        XCTAssertTrue(popoverIsOpen())
        effort.performClick(nil)
        XCTAssertEqual([model.state, effort.state], [.off, .on])
        XCTAssertTrue(popoverIsOpen())
        effort.performClick(nil)
        XCTAssertEqual(effort.state, .off)
        XCTAssertFalse(popoverIsOpen())
    }

    // MARK: - Dimming the words

    /// A sent prompt waiting for its session: the words and the token go to half
    /// strength, the card and its buttons stay as they were.
    func testDimmingTheFieldDimsOnlyItsWordsAndToken() throws {
        try XCTUnwrap(find(ComposerView.self)).complete(command: "review")
        try type("the diff")
        let words = try XCTUnwrap(try textView().enclosingScrollView)
        let token = try XCTUnwrap(
            find(NSView.self) { String(describing: Swift.type(of: $0)).contains("CommandTokenView") })
        let button = try XCTUnwrap(find(MenuButton.self))

        composer.isFieldDimmed = true

        XCTAssertEqual(words.alphaValue, 0.5)
        XCTAssertEqual(token.alphaValue, 0.5)
        XCTAssertEqual(composer.view.alphaValue, 1, "the card is not dimmed")
        XCTAssertEqual(button.alphaValue, 1, "a menu button is not dimmed")
        XCTAssertEqual(composer.text, "/review the diff", "the words are untouched")

        composer.isFieldDimmed = false
        XCTAssertEqual(words.alphaValue, 1)
        XCTAssertEqual(token.alphaValue, 1)
    }

    // MARK: Placement

    private var keyHints: NSTextField? {
        find(NSTextField.self) { $0.stringValue.contains("⇧⇥") }
    }

    /// In a page the key hints sit 12 under the card, in the 16-pt line the
    /// view ends on; floating, the view is the card alone.
    func testInAPageTheKeyHintsSitUnderTheCard() throws {
        configure(F.newTab)
        window.layoutIfNeeded()
        let card = try XCTUnwrap(find(ComposerView.self))
        let hints = try XCTUnwrap(keyHints)
        XCTAssertFalse(hints.isHidden)
        XCTAssertEqual(card.frame.minY, 12 + 16, accuracy: 0.5)
        XCTAssertEqual(hints.frame.midY, 8, accuracy: 0.5)

        configure(F.idle)
        window.layoutIfNeeded()
        XCTAssertTrue(hints.isHidden)
        XCTAssertEqual(card.frame, composer.view.bounds)
    }

    /// The hints are for an empty field: words fade them out, and clearing
    /// the field brings them back.
    func testTheKeyHintsShowOnlyWhileTheFieldIsEmpty() throws {
        configure(F.newTab)
        let hints = try XCTUnwrap(keyHints)
        XCTAssertEqual(hints.alphaValue, 1)

        composer.text = "Fix the gutter"
        wait(for: [expectation(for: NSPredicate { _, _ in hints.alphaValue == 0 }, evaluatedWith: nil)], timeout: 2)
        composer.text = ""
        wait(for: [expectation(for: NSPredicate { _, _ in hints.alphaValue == 1 }, evaluatedWith: nil)], timeout: 2)
    }
}

/// A responder above the composer, counting the ⎋ that reach it.
private final class CancelRecorder: NSResponder {
    var cancels = 0
    override func cancelOperation(_ sender: Any?) { cancels += 1 }
}

extension ComposerViewController {
    /// The card's height once laid out, as a container placing it reads it.
    var fittedHeight: CGFloat {
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }
}

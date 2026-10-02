import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// What the composer reports, driven the way its controls are: the keys go
/// through the field's command selectors, the buttons through `performClick`,
/// the menus through the items they build.
@MainActor
final class ComposerViewControllerTests: XCTestCase {
    private typealias F = ComposerFixtures

    private final class Recorder: ComposerViewControllerDelegate {
        var submitted: [String] = []
        var stops = 0
        var changes: [SessionSettings.Change] = []
        var restarts = 0
        var logs = 0
        var waiting = 0
        var contexts = 0
        var textChanges = 0
        func composerViewController(_ c: ComposerViewController, didSubmit text: String) { submitted.append(text) }
        func composerViewControllerDidRequestStop(_ c: ComposerViewController) { stops += 1 }
        func composerViewController(_ c: ComposerViewController, didChoose change: SessionSettings.Change) {
            changes.append(change)
        }
        func composerViewControllerDidRequestRestart(_ c: ComposerViewController) { restarts += 1 }
        func composerViewControllerDidRequestLog(_ c: ComposerViewController) { logs += 1 }
        func composerViewControllerDidRequestWaitingRequest(_ c: ComposerViewController) { waiting += 1 }
        func composerViewControllerDidRequestContextUsage(_ c: ComposerViewController) { contexts += 1 }
        func composerViewControllerDidChangeText(_ c: ComposerViewController) { textChanges += 1 }
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
        configure(F.model(F.session(.idle)))
        window.layoutIfNeeded()
    }

    override func tearDown() {
        window.close()
    }

    private func configure(_ model: ComposerModel) {
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

    private func button(_ label: String) -> NSButton? {
        find(NSButton.self) { $0.accessibilityLabel() == label }
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
        let send = try XCTUnwrap(button(String(localized: "Send")))
        XCTAssertFalse(send.isEnabled)
        try type("run it")
        XCTAssertTrue(send.isEnabled)
        send.performClick(nil)
        XCTAssertEqual(recorder.submitted, ["run it"])
        XCTAssertFalse(send.isEnabled)
    }

    func testWhileClaudeWorksStopIsShownAndTheArrowAppearsWithWords() throws {
        configure(F.model(F.session(.responding)))
        let stop = try XCTUnwrap(button(String(localized: "Stop")))
        let send = try XCTUnwrap(button(String(localized: "Send")))
        XCTAssertFalse(stop.isHidden)
        XCTAssertTrue(send.isHidden)
        try type("and the docs")
        XCTAssertFalse(send.isHidden)
        stop.performClick(nil)
        XCTAssertEqual(recorder.stops, 1)
    }

    func testEscapeDoesNotStop() throws {
        // ⌘. and ⎋ both arrive as cancelOperation; the field tells them by the
        // event, and with none in flight it is ⎋, which the permission card owns.
        configure(F.model(F.session(.responding)))
        XCTAssertFalse(try press(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(recorder.stops, 0)
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

    func testATokenAloneCanBeSent() throws {
        composer.text = "/context"
        XCTAssertTrue(try press(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(recorder.submitted, ["/context"])
    }

    func testTheFieldGrowsWithItsWordsAndStopsAtEightLines() throws {
        let before = composer.cardHeight
        composer.text = (1...3).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(composer.cardHeight - before, 44, accuracy: 2)
        composer.text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        composer.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(composer.cardHeight - before, 22 * 7, accuracy: 2)
    }

    // MARK: Keys

    /// Needs `SessionSettings.nextCycledMode` (workstream B).
    func testShiftTabChoosesTheNextMode() throws {
        configure(F.model(F.session(.idle), settings: F.settings("opus", mode: .default)))
        XCTAssertTrue(try press(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(recorder.changes, [.permissionMode(.acceptEdits)])
    }

    func testShiftTabIsSwallowedWhenThereIsNothingToChoose() throws {
        configure(F.model(.draft, settings: nil, catalog: ModelCatalog()))
        XCTAssertTrue(try press(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(recorder.changes, [])
    }

    func testEscapeIsLeftToThePermissionCard() throws {
        XCTAssertFalse(try press(#selector(NSResponder.cancelOperation(_:))))
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
        configure(F.model(F.session(.failed(SessionFailure(message: "Exit code 1 · boom")))))
        try XCTUnwrap(button(String(localized: "Restart"))).performClick(nil)
        try XCTUnwrap(button(String(localized: "Show Log"))).performClick(nil)
        XCTAssertEqual(recorder.restarts, 1)
        XCTAssertEqual(recorder.logs, 1)
    }

    func testTheContextRingOpensTheContext() throws {
        configure(F.model(F.session(.idle), usage: 0.72))
        let ring = try XCTUnwrap(find(ContextRingView.self))
        XCTAssertFalse(ring.isHidden)
        ring.mouseDown(with: NSEvent())
        XCTAssertEqual(recorder.contexts, 1)
        configure(F.model(F.session(.idle), usage: 0.3))
        XCTAssertTrue(ring.isHidden)
    }

    // MARK: Menus

    func testTheEffortMenuIsBuiltFromTheModelAndChoosingAnItemReportsItsChange() throws {
        let model = F.model(F.session(.idle), settings: F.settings("sonnet-4-6", effort: .high))
        let menu = ComposerMenu.make(model.effortMenu, target: self, action: #selector(chosen(_:)))
        let items = menu.items.filter { !$0.isSectionHeader && !$0.isSeparatorItem }
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(menu.items.first?.isSectionHeader, true)
        XCTAssertEqual(items.map(\.state), [.off, .off, .on, .off, .off])
        XCTAssertEqual(items.map(\.isEnabled), [true, true, true, false, true])
        let choice = try XCTUnwrap(items[1].representedObject as? ComposerMenu.Choice)
        XCTAssertEqual(choice.change, .effort(.medium))
    }

    func testTheModeMenuSetsBypassApartAndMarksTheCurrentMode() {
        let model = F.model(F.session(.idle), settings: F.settings("opus", mode: .plan))
        let menu = ComposerMenu.make(model.modeMenu, target: self, action: #selector(chosen(_:)))
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
        XCTAssertEqual(menu.items.last?.title, model.modeMenu.sections[1].items[0].title)
        XCTAssertEqual(menu.items.filter { $0.state == .on }.count, 1)
    }

    @objc private func chosen(_ sender: NSMenuItem) {}

    // MARK: The model panel

    func testThePanelListsTheNoteThenEachAccountsHeaderModelsAndItsMoreRow() {
        let model = F.model(F.session(.responding), settings: F.settings("opus"))
        let rows = ModelPanelViewController.rows(for: model, expanded: [])
        guard case .note = rows.first else { return XCTFail("no note over the sections") }
        let headers = rows.compactMap { row -> String? in
            if case .header(let section) = row { section.name } else { nil }
        }
        XCTAssertEqual(headers, ["Claude Max", "Work Relay", "DeepSeek"])
        let more = rows.compactMap { row -> Int? in
            if case .more(_, let count) = row { count } else { nil }
        }
        XCTAssertEqual(more, [7])
    }

    func testExpandingMoreModelsPutsTheFoldedOnesInPlace() {
        let model = F.model(.draft, settings: F.settings("opus"))
        let rows = ModelPanelViewController.rows(for: model, expanded: [F.subscription])
        let titles = rows.compactMap { row -> String? in
            if case .item(let item) = row { item.title } else { nil }
        }
        XCTAssertEqual(titles.prefix(12).last, "Sonnet 4.6")
        XCTAssertFalse(rows.contains { if case .more = $0 { true } else { false } })
    }

    func testThePanelFollowsTheModelAndOpensWithinItsHeightLimit() {
        let panel = ModelPanelViewController()
        panel.configure(with: F.model(.draft, settings: F.settings("opus")))
        XCTAssertLessThanOrEqual(
            panel.preferredHeight, ModelPanelViewController.maxScrollHeight + 60)
        XCTAssertGreaterThan(panel.preferredHeight, 200)
    }
}

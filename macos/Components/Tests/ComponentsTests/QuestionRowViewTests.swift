import AppKit
import DisplayModels
import XCTest

@testable import Components

/// The question card's options as the sheet sets them (`.qa .opt`: 4 pt
/// above and below, the label on 18-pt lines, the description on 16; *Other*
/// one 26-pt line with a tertiary placeholder), and a card *Chat About This*
/// answered, which keeps its questions without their options (07-talk.md).
@MainActor
final class QuestionRowViewTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func mount(_ model: Question) -> (QuestionRowView, RowStage) {
        let view = QuestionRowView()
        view.configure(with: model)
        return (view, RowStage(view, size: CGSize(width: 520, height: 400)))
    }

    private func label(_ words: String, in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == words }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        descendants(of: view).compactMap { $0 as? NSButton }
    }

    /// The option button whose title's first line is `label`.
    private func option(_ label: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(
            buttons(in: view).first {
                $0.attributedTitle.string.components(separatedBy: "\n").first == label
            }, label)
    }

    /// Presses `button` where a reader would — on its mark when it has no
    /// words, else at the start of its label (`line` 0) or its description
    /// (`line` 1) — once the window's hit test finds it there.
    private func press(_ button: NSButton, line: Int = 0, file: StaticString = #filePath, fileLine: UInt = #line) {
        let x: CGFloat = button.attributedTitle.length == 0 ? 8 : 26
        // From the top: 4 of padding, then the 18-pt label's middle, or the
        // 16-pt description's under it.
        let fromTop: CGFloat = button.attributedTitle.length == 0 ? button.bounds.midY : line == 0 ? 4 + 9 : 4 + 18 + 8
        let y = button.isFlipped ? fromTop : button.bounds.height - fromTop
        XCTAssertTrue(
            button.hitInWindow(at: NSPoint(x: x, y: y)) === button, "the button is under the pointer", file: file,
            line: fileLine)
        button.performClick(nil)
    }

    /// *Other*'s field and its button.
    private func other(in view: NSView) throws -> (NSTextField, NSButton) {
        let field = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.placeholderAttributedString != nil })
        let words = field.placeholderAttributedString?.string
        return (field, try XCTUnwrap(buttons(in: view).first { $0.accessibilityLabel() == words }))
    }

    /// A live option is one radio button titled with both its lines; its row
    /// is the button's own measure and 4 above and below.
    func testALiveOptionIsARadioButtonTitledWithBothLines() throws {
        let (view, stage) = mount(RowModels.layout(previews: false))
        defer { stage.teardown() }
        let split = try option("Split", in: view)
        XCTAssertEqual(split.attributedTitle.string, "Split\nTwo")
        XCTAssertEqual(split.cell?.accessibilityRole(), .radioButton)
        let cell = try XCTUnwrap(split.cell)
        let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: split.frame.width, height: 1000)).height
        XCTAssertEqual(split.frame.height, ceil(measured) + 8)
        XCTAssertNil(label("Split", in: view), "no label of its own beside the button")
    }

    /// A press on an option picks it; its question's radio buttons are one
    /// group, so the next press moves the pick.
    func testAClickPicksAndTheGroupFollows() throws {
        let (view, stage) = mount(RowModels.layout(previews: false))
        defer { stage.teardown() }
        let split = try option("Split", in: view)
        let tabs = try option("Tabs", in: view)
        press(split)
        XCTAssertEqual(split.state, .on)
        // Its description's words take the press too.
        press(tabs, line: 1)
        XCTAssertEqual(tabs.state, .on)
        XCTAssertEqual(split.state, .off)
    }

    /// Every question is a group of its own; a multi-select's checkboxes add up.
    func testEachQuestionIsAGroupOfItsOwn() throws {
        let (view, stage) = mount(RowModels.several(waiting: true))
        defer { stage.teardown() }
        let macOS = try option("macOS", in: view)
        let iOS = try option("iOS", in: view)
        let yes = try option("Yes", in: view)
        XCTAssertEqual(macOS.cell?.accessibilityRole(), .checkBox)
        XCTAssertEqual(yes.cell?.accessibilityRole(), .radioButton)
        press(macOS)
        press(iOS)
        press(yes)
        XCTAssertEqual([macOS.state, iOS.state, yes.state], [.on, .on, .on])
        press(macOS)
        XCTAssertEqual(macOS.state, .off)
    }

    /// *Other* is a radio button beside a one-line field with a tertiary
    /// placeholder, 26 tall; typing in the field picks it alone.
    func testTypingInOtherPicksItAlone() throws {
        let (view, stage) = mount(RowModels.layout(previews: false))
        defer { stage.teardown() }
        let (field, other) = try other(in: view)
        let placeholder = try XCTUnwrap(field.placeholderAttributedString)
        XCTAssertEqual(
            placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .tertiaryLabelColor)
        XCTAssertEqual(other.frame.height, 26)
        let split = try option("Split", in: view)
        press(split)
        field.stringValue = "Both"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(other.state, .on)
        XCTAssertEqual(split.state, .off)
    }

    /// Pressing *Other* hands the keyboard to its field.
    func testPressingOtherFocusesItsField() throws {
        let (view, stage) = mount(RowModels.layout(previews: false))
        defer { stage.teardown() }
        let (field, other) = try other(in: view)
        press(other)
        XCTAssertEqual(other.state, .on)
        XCTAssertNotNil(field.currentEditor())
    }

    /// `.qa .submit` 8 apart; *Chat About This* is a `.btn.plain`, a pill
    /// without its fill, so its words are 14 in from its box.
    func testChatAboutThisIsAPlainPillEightAfterSubmit() throws {
        let (view, stage) = mount(RowModels.layout(previews: false))
        defer { stage.teardown() }
        let buttons = descendants(of: view).compactMap { $0 as? NSButton }
        let submit = try XCTUnwrap(buttons.first { $0 is PillButton })
        let chat = try XCTUnwrap(
            buttons.first { $0.attributedTitle.string == String(localized: "Chat About This", bundle: .module) })
        XCTAssertEqual(chat.frame.minX - submit.frame.maxX, 8)
        XCTAssertEqual(chat.frame.width, ceil(chat.attributedTitle.size().width) + 28)
    }

    func testATalkedOverCardKeepsItsQuestionsWithoutTheirOptions() throws {
        let model = RowModels.layout(
            previews: false, waiting: false, outcome: RowModels.talkedOver, talkedOver: true)
        XCTAssertTrue(model.isTalkedOver)
        let answered = RowModels.layout(previews: false, waiting: false, outcome: RowModels.notAnswered)
        XCTAssertFalse(answered.isTalkedOver)
        let (view, stage) = mount(model)
        defer { stage.teardown() }
        XCTAssertNotNil(label("Which layout?", in: view))
        XCTAssertNil(label("Split", in: view))
        XCTAssertNil(label("Tabs", in: view))
        // `.qa .qnote`: 12-pt words, 4 under the question's 6.
        let note = try XCTUnwrap(label(RowModels.talkedOver, in: view))
        XCTAssertEqual(note.font?.pointSize, 12)
        let asked = try XCTUnwrap(label("Which layout?", in: view))
        XCTAssertEqual(note.frame.minY - asked.frame.maxY, 6 + 4)
        XCTAssertLessThan(
            QuestionRowView.height(for: model, width: 520), QuestionRowView.height(for: answered, width: 520))
    }
}

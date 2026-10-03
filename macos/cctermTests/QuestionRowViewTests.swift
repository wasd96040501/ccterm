import AgentSDK
import AppKit
import DisplayModels
import XCTest

@testable import ccterm

/// The question card's options as the sheet sets them (`.qa .opt`: 4 pt
/// above and below, the label on 18-pt lines, the description on 16; *Other*
/// one 26-pt line with a tertiary placeholder), and a card *Chat About This*
/// answered, which keeps its questions without their options (07-talk.md).
@MainActor
final class QuestionRowViewTests: XCTestCase {
    private static let json =
        #"[{"question":"Which layout?","header":"Layout","options":[{"label":"Split","description":"Two"},{"label":"Tabs","description":"One"}],"multiSelect":false}]"#

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func question(_ state: ToolCallState) throws -> Question {
        let input = try JSONDecoder().decode(
            Tools.AskUserQuestion.Input.self, from: Data(#"{"questions":\#(Self.json)}"#.utf8))
        let use = ToolUseBlock(id: "q", name: "AskUserQuestion", input: MessageScript.json("{}"))
        let call = ToolCall(use: use, result: nil, kind: .other, state: state, startedAt: nil, finishedAt: nil)
        return Question(call: call, questions: input.questions, answers: [:])
    }

    private func mount(_ model: Question) -> (QuestionRowView, AppKitStage) {
        let view = QuestionRowView()
        view.configure(with: model)
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        view.frame = host.view.bounds
        host.view.addSubview(view)
        let stage = AppKitStage.mount(host, size: CGSize(width: 520, height: 400))
        view.frame = host.view.bounds
        view.layoutSubtreeIfNeeded()
        return (view, stage)
    }

    private func label(_ words: String, in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == words }
    }

    private static let talkedOver = "The user wants to clarify these questions. Ask them what they meant."

    func testAnOptionIsFourAboveAndBelowAnEighteenPointLabelAndASixteenPointDescription() throws {
        let (view, stage) = mount(try question(.waiting(reason: nil)))
        defer { stage.teardown() }
        let option = try XCTUnwrap(label("Split", in: view)?.superview)
        XCTAssertEqual(option.frame.height, 4 + 18 + 16 + 4)
        XCTAssertEqual(try XCTUnwrap(label("Split", in: view)).frame.height, 18)
        XCTAssertEqual(try XCTUnwrap(label("Two", in: view)).frame.height, 16)
    }

    func testOtherIsOneLineWithATertiaryPlaceholder() throws {
        let (view, stage) = mount(try question(.waiting(reason: nil)))
        defer { stage.teardown() }
        let field = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.placeholderAttributedString != nil })
        let placeholder = try XCTUnwrap(field.placeholderAttributedString)
        XCTAssertEqual(
            placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .tertiaryLabelColor)
        XCTAssertEqual(try XCTUnwrap(field.superview).frame.height, 26)
    }

    /// `.qa .submit` 8 apart; *Chat About This* is a `.btn.plain`, a pill
    /// without its fill, so its words are 14 in from its box.
    func testChatAboutThisIsAPlainPillEightAfterSubmit() throws {
        let (view, stage) = mount(try question(.waiting(reason: nil)))
        defer { stage.teardown() }
        let buttons = descendants(of: view).compactMap { $0 as? NSButton }
        let submit = try XCTUnwrap(buttons.first { $0 is PillButton })
        let chat = try XCTUnwrap(buttons.first { $0.attributedTitle.string == String(localized: "Chat About This") })
        XCTAssertEqual(chat.frame.minX - submit.frame.maxX, 8)
        XCTAssertEqual(chat.frame.width, ceil(chat.attributedTitle.size().width) + 28)
    }

    func testATalkedOverCardKeepsItsQuestionsWithoutTheirOptions() throws {
        let model = try question(.failed(message: Self.talkedOver))
        XCTAssertTrue(model.isTalkedOver)
        XCTAssertFalse(try question(.failed(message: "User declined to answer questions")).isTalkedOver)
        let (view, stage) = mount(model)
        defer { stage.teardown() }
        XCTAssertNotNil(label("Which layout?", in: view))
        XCTAssertNil(label("Split", in: view))
        XCTAssertNil(label("Tabs", in: view))
        // `.qa .qnote`: 12-pt words, 4 under the question's 6.
        let note = try XCTUnwrap(label(String(localized: "Not answered — talked over in the conversation"), in: view))
        XCTAssertEqual(note.font?.pointSize, 12)
        let asked = try XCTUnwrap(label("Which layout?", in: view))
        XCTAssertEqual(note.frame.minY - asked.frame.maxY, 6 + 4)
        let answered = try question(.failed(message: "User declined to answer questions"))
        XCTAssertLessThan(
            QuestionRowView.height(for: model, width: 520), QuestionRowView.height(for: answered, width: 520))
    }
}

import AgentSDK
import AppKit
import Components
import DisplayModels
import XCTest

@testable import ccterm

/// `QuestionRowView` in every state, light above dark, beside the design
/// (07-talk.md "AskUserQuestion"; preview.css `.qa`). Review only —
/// `make test-unit FILTER=QuestionRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/QuestionRowView.png`.
@MainActor
final class QuestionRowViewSnapshotTests: XCTestCase {
    private func question(_ json: String, answers: [String: String], waiting: Bool = false) throws -> Question {
        let input = try JSONDecoder().decode(
            Tools.AskUserQuestion.Input.self, from: Data(#"{"questions":\#(json)}"#.utf8))
        let use = ToolUseBlock(id: "q", name: "AskUserQuestion", input: MessageScript.json("{}"))
        let call = ToolCall(
            use: use, result: nil, kind: .other, state: waiting ? .waiting(reason: nil) : .done, startedAt: nil,
            finishedAt: nil)
        return Question(call: call, questions: input.questions, answers: answers)
    }

    private static let one =
        #"[{"question":"Which library should we use for date formatting?","header":"Auth method","options":[{"label":"date-fns","description":"Small, tree-shakeable"},{"label":"Moment","description":""}],"multiSelect":false}]"#
    private static let several =
        #"[{"question":"Which platforms should the first release support, and is there anything about the split editor we should settle before then?","header":"Targets","options":[{"label":"macOS","description":"14 and later"},{"label":"iOS","description":""},{"label":"visionOS","description":"Later"}],"multiSelect":true},{"question":"Ship it?","header":"Release","options":[{"label":"Yes","description":""},{"label":"No","description":"Wait for the next build"}],"multiSelect":false}]"#

    private static let previewed =
        #"[{"question":"Which layout do you want?","header":"Layout","options":[{"label":"Split","description":"Two editors side by side","preview":"+------+------+\n| code | doc  |\n+------+------+"},{"label":"Tabs","description":"One editor, many tabs","preview":"[a][b][c]\n+---------+\n| editor  |\n+---------+"}],"multiSelect":false}]"#

    private func failed(_ json: String, _ message: String) throws -> Question {
        var model = try question(json, answers: [:])
        let call = ToolCall(
            use: ToolUseBlock(id: "q", name: "AskUserQuestion", input: MessageScript.json("{}")), result: nil,
            kind: .other, state: .failed(message: message), startedAt: nil,
            finishedAt: nil)
        model = Question(
            call: call,
            questions: try JSONDecoder().decode(
                Tools.AskUserQuestion.Input.self, from: Data(#"{"questions":\#(json)}"#.utf8)
            ).questions, answers: [:])
        return model
    }

    private func models() throws -> [Question] {
        [
            try question(Self.one, answers: ["Which library should we use for date formatting?": "Day.js"]),
            try failed(Self.one, "The user wants to clarify these questions. Start by asking."),
            try question(Self.previewed, answers: [:], waiting: true),
            try question(Self.one, answers: ["Which library should we use for date formatting?": "date-fns"]),
            try question(
                Self.several,
                answers: [
                    "Which platforms should the first release support, and is there anything about the split editor we should settle before then?":
                        "macOS, iOS",
                    "Ship it?": "Yes",
                ]),
            try question(Self.one, answers: [:], waiting: true),
            try question(Self.several, answers: [:], waiting: true),
        ]
    }

    func testEveryState() throws {
        RowSnapshot.render(
            QuestionRowView.self, try models(), widths: [520, 320], gap: 14, name: "QuestionRowView", test: self)
    }
}

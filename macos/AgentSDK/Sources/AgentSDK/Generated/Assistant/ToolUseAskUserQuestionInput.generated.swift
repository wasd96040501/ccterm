import Foundation

public struct ToolUseAskUserQuestionInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let questions: [InputQuestions]?
}

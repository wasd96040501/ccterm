import Foundation

public struct AskUserQuestionQuestions: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let header: String?
    public let multiSelect: Bool?
    public let options: [QuestionsOptions]?
    public let question: String?
}

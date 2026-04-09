import Foundation

public struct ObjectAskUserQuestion: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let annotations: [String: AnnotationsValue]?
    public let answers: [String: String]?
    public let questions: [AskUserQuestionQuestions]?
}

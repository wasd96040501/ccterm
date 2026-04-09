import Foundation

public struct TaskInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let description: String?
    public let model: String?
    public let prompt: String?
    public let resume: String?
    public let runInBackground: Bool?
    public let subagentType: String?
}

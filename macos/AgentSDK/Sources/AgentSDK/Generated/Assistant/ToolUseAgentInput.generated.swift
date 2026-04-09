import Foundation

public struct ToolUseAgentInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let description: String?
    public let isolation: String?
    public let mode: String?
    public let model: String?
    public let name: String?
    public let prompt: String?
    public let resume: String?
    public let runInBackground: Bool?
    public let subagentType: String?
    public let teamName: String?
}

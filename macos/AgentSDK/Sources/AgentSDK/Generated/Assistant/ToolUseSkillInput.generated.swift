import Foundation

public struct ToolUseSkillInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let args: String?
    public let skill: String?
}

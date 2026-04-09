import Foundation

public struct ToolUseGrep: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseGrepInput?
}

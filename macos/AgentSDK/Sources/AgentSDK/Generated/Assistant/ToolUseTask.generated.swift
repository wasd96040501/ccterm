import Foundation

public struct ToolUseTask: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: TaskInput?
}

import Foundation

public struct ContentEdit: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseEditInput?
    public let `type`: String?
}

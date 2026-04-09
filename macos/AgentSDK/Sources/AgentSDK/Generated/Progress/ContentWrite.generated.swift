import Foundation

public struct ContentWrite: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseWriteInput?
    public let `type`: String?
}

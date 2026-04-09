import Foundation

public struct ContentGlob: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseGlobInput?
    public let `type`: String?
}

import Foundation

public struct ToolUseGlobInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let path: String?
    public let pattern: String?
}

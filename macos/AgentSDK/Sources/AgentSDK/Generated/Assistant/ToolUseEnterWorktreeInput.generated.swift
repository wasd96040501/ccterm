import Foundation

public struct ToolUseEnterWorktreeInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let name: String?
}

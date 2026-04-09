import Foundation

public struct ToolUseExitWorktreeInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let action: String?
}

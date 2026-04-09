import Foundation

public struct ToolUseEnterWorktree: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseEnterWorktreeInput?
}

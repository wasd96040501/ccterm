import Foundation

public struct ToolUseExitWorktree: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseExitWorktreeInput?
}

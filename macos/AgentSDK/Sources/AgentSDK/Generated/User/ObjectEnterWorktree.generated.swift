import Foundation

public struct ObjectEnterWorktree: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let message: String?
    public let worktreeBranch: String?
    public let worktreePath: String?
}

import Foundation

public struct ObjectExitWorktree: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let action: String?
    public let message: String?
    public let originalCwd: String?
    public let worktreeBranch: String?
    public let worktreePath: String?
}

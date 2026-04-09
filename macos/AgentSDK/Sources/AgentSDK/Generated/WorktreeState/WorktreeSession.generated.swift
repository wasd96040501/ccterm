import Foundation

public struct WorktreeSession: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let originalBranch: String?
    public let originalCwd: String?
    public let originalHeadCommit: String?
    public let sessionId: String?
    public let worktreeBranch: String?
    public let worktreeName: String?
    public let worktreePath: String?
}

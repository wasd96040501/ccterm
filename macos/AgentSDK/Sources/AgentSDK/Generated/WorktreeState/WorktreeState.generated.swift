import Foundation

public struct WorktreeState: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let sessionId: String?
    public let worktreeSession: WorktreeSession?
}

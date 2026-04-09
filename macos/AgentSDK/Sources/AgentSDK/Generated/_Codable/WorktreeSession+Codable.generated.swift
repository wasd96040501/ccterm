import Foundation

extension WorktreeSession {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "WorktreeSession")
        self._raw = r.dict
        self.originalBranch = r.string("original_branch", alt: "originalBranch")
        self.originalCwd = r.string("original_cwd", alt: "originalCwd")
        self.originalHeadCommit = r.string("original_head_commit", alt: "originalHeadCommit")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.worktreeBranch = r.string("worktree_branch", alt: "worktreeBranch")
        self.worktreeName = r.string("worktree_name", alt: "worktreeName")
        self.worktreePath = r.string("worktree_path", alt: "worktreePath")
    }

    public func toJSON() -> Any { _raw }
}

extension WorktreeSession {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = originalBranch { d["original_branch"] = v }
        if let v = originalCwd { d["original_cwd"] = v }
        if let v = originalHeadCommit { d["original_head_commit"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = worktreeBranch { d["worktree_branch"] = v }
        if let v = worktreeName { d["worktree_name"] = v }
        if let v = worktreePath { d["worktree_path"] = v }
        return d
    }
}

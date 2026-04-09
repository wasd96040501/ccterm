import Foundation

extension ObjectExitWorktree {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectExitWorktree")
        self._raw = r.dict
        self.action = r.string("action")
        self.message = r.string("message")
        self.originalCwd = r.string("original_cwd", alt: "originalCwd")
        self.worktreeBranch = r.string("worktree_branch", alt: "worktreeBranch")
        self.worktreePath = r.string("worktree_path", alt: "worktreePath")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectExitWorktree {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = action { d["action"] = v }
        if let v = message { d["message"] = v }
        if let v = originalCwd { d["original_cwd"] = v }
        if let v = worktreeBranch { d["worktree_branch"] = v }
        if let v = worktreePath { d["worktree_path"] = v }
        return d
    }
}

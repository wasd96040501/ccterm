import Foundation

extension ObjectEnterWorktree {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectEnterWorktree")
        self._raw = r.dict
        self.message = r.string("message")
        self.worktreeBranch = r.string("worktree_branch", alt: "worktreeBranch")
        self.worktreePath = r.string("worktree_path", alt: "worktreePath")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectEnterWorktree {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = message { d["message"] = v }
        if let v = worktreeBranch { d["worktree_branch"] = v }
        if let v = worktreePath { d["worktree_path"] = v }
        return d
    }
}

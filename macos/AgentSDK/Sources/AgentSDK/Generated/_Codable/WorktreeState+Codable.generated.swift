import Foundation

extension WorktreeState {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "WorktreeState")
        self._raw = r.dict
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.worktreeSession = r.decodeIfPresent("worktree_session", alt: "worktreeSession")
    }

    public func toJSON() -> Any { _raw }
}

extension WorktreeState {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = sessionId { d["session_id"] = v }
        if let v = worktreeSession { d["worktree_session"] = v.toTypedJSON() }
        return d
    }
}

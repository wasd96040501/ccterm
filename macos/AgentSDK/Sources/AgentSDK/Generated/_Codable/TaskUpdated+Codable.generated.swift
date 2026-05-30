import Foundation

extension TaskUpdated {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskUpdated")
        self._raw = r.dict
        self.patch = r.decodeIfPresent("patch")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.taskId = r.string("task_id", alt: "taskId")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskUpdated {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = patch { d["patch"] = v.toTypedJSON() }
        if let v = sessionId { d["session_id"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = toolUseId { d["tool_use_id"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

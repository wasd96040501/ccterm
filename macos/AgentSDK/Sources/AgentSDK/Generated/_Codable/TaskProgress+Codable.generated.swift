import Foundation

extension TaskProgress {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskProgress")
        self._raw = r.dict
        self.description = r.string("description")
        self.lastToolName = r.string("last_tool_name")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.taskId = r.string("task_id", alt: "taskId")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
        self.usage = r.decodeIfPresent("usage")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskProgress {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = description { d["description"] = v }
        if let v = lastToolName { d["last_tool_name"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = toolUseId { d["tool_use_id"] = v }
        if let v = usage { d["usage"] = v.toTypedJSON() }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

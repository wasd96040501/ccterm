import Foundation

extension TaskStarted {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskStarted")
        self._raw = r.dict
        self.description = r.string("description")
        self.prompt = r.string("prompt")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.taskId = r.string("task_id", alt: "taskId")
        self.taskType = r.string("task_type", alt: "taskType")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskStarted {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = description { d["description"] = v }
        if let v = prompt { d["prompt"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = taskType { d["task_type"] = v }
        if let v = toolUseId { d["tool_use_id"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

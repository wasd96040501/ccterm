import Foundation

extension TaskNotification {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskNotification")
        self._raw = r.dict
        self.outputFile = r.string("output_file", alt: "outputFile")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.status = r.string("status")
        self.summary = r.string("summary")
        self.taskId = r.string("task_id", alt: "taskId")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
        self.usage = r.decodeIfPresent("usage")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskNotification {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = outputFile { d["output_file"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = status { d["status"] = v }
        if let v = summary { d["summary"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = toolUseId { d["tool_use_id"] = v }
        if let v = usage { d["usage"] = v.toTypedJSON() }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

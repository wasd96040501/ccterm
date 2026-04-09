import Foundation

extension ObjectTaskStop {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectTaskStop")
        self._raw = r.dict
        self.command = r.string("command")
        self.message = r.string("message")
        self.taskId = r.string("task_id", alt: "taskId")
        self.taskType = r.string("task_type", alt: "taskType")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectTaskStop {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = command { d["command"] = v }
        if let v = message { d["message"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = taskType { d["task_type"] = v }
        return d
    }
}

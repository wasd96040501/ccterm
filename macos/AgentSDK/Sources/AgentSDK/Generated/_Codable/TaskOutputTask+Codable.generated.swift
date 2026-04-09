import Foundation

extension TaskOutputTask {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskOutputTask")
        self._raw = r.dict
        self.description = r.string("description")
        self.exitCode = r.int("exit_code", alt: "exitCode")
        self.output = r.string("output")
        self.status = r.string("status")
        self.taskId = r.string("task_id", alt: "taskId")
        self.taskType = r.string("task_type", alt: "taskType")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskOutputTask {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = description { d["description"] = v }
        if let v = exitCode { d["exit_code"] = v }
        if let v = output { d["output"] = v }
        if let v = status { d["status"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = taskType { d["task_type"] = v }
        return d
    }
}

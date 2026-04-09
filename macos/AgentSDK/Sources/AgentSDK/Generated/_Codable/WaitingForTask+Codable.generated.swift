import Foundation

extension WaitingForTask {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "WaitingForTask")
        self._raw = r.dict
        self.taskDescription = r.string("task_description", alt: "taskDescription")
        self.taskType = r.string("task_type", alt: "taskType")
    }

    public func toJSON() -> Any { _raw }
}

extension WaitingForTask {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = taskDescription { d["task_description"] = v }
        if let v = taskType { d["task_type"] = v }
        return d
    }
}

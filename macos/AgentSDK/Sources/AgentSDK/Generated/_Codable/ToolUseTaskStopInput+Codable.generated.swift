import Foundation

extension ToolUseTaskStopInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseTaskStopInput")
        self._raw = r.dict
        self.taskId = r.string("task_id", alt: "taskId")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseTaskStopInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = taskId { d["task_id"] = v }
        return d
    }
}

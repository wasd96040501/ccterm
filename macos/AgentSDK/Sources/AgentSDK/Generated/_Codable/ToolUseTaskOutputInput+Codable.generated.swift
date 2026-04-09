import Foundation

extension ToolUseTaskOutputInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseTaskOutputInput")
        self._raw = r.dict
        self.block = r.bool("block")
        self.taskId = r.string("task_id", alt: "taskId")
        self.timeout = r.int("timeout")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseTaskOutputInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = block { d["block"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = timeout { d["timeout"] = v }
        return d
    }
}

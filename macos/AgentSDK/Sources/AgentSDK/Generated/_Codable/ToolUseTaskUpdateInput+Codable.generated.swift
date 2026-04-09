import Foundation

extension ToolUseTaskUpdateInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseTaskUpdateInput")
        self._raw = r.dict
        self.activeForm = r.string("active_form", alt: "activeForm")
        self.addBlockedBy = r.stringArray("add_blocked_by", alt: "addBlockedBy")
        self.description = r.string("description")
        self.owner = r.string("owner")
        self.status = r.string("status")
        self.taskId = r.string("task_id", alt: "taskId")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseTaskUpdateInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = activeForm { d["active_form"] = v }
        if let v = addBlockedBy { d["add_blocked_by"] = v }
        if let v = description { d["description"] = v }
        if let v = owner { d["owner"] = v }
        if let v = status { d["status"] = v }
        if let v = taskId { d["task_id"] = v }
        return d
    }
}

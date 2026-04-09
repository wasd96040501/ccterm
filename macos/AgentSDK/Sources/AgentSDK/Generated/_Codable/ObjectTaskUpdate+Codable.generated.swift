import Foundation

extension ObjectTaskUpdate {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectTaskUpdate")
        self._raw = r.dict
        self.error = r.string("error")
        self.statusChange = r.decodeIfPresent("status_change", alt: "statusChange")
        self.success = r.bool("success")
        self.taskId = r.string("task_id", alt: "taskId")
        self.updatedFields = r.stringArray("updated_fields", alt: "updatedFields")
        self.verificationNudgeNeeded = r.bool("verification_nudge_needed", alt: "verificationNudgeNeeded")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectTaskUpdate {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = error { d["error"] = v }
        if let v = statusChange { d["status_change"] = v.toTypedJSON() }
        if let v = success { d["success"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = updatedFields { d["updated_fields"] = v }
        if let v = verificationNudgeNeeded { d["verification_nudge_needed"] = v }
        return d
    }
}

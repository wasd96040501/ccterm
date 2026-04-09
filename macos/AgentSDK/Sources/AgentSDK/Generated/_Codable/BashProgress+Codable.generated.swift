import Foundation

extension BashProgress {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "BashProgress")
        self._raw = r.dict
        self.elapsedTimeSeconds = r.int("elapsed_time_seconds", alt: "elapsedTimeSeconds")
        self.fullOutput = r.string("full_output", alt: "fullOutput")
        self.output = r.string("output")
        self.taskId = r.string("task_id", alt: "taskId")
        self.timeoutMs = r.int("timeout_ms", alt: "timeoutMs")
        self.totalBytes = r.int("total_bytes", alt: "totalBytes")
        self.totalLines = r.int("total_lines", alt: "totalLines")
    }

    public func toJSON() -> Any { _raw }
}

extension BashProgress {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = elapsedTimeSeconds { d["elapsed_time_seconds"] = v }
        if let v = fullOutput { d["full_output"] = v }
        if let v = output { d["output"] = v }
        if let v = taskId { d["task_id"] = v }
        if let v = timeoutMs { d["timeout_ms"] = v }
        if let v = totalBytes { d["total_bytes"] = v }
        if let v = totalLines { d["total_lines"] = v }
        return d
    }
}

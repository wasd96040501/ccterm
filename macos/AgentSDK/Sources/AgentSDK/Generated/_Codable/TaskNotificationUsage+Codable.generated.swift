import Foundation

extension TaskNotificationUsage {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskNotificationUsage")
        self._raw = r.dict
        self.durationMs = r.int("duration_ms", alt: "durationMs")
        self.toolUses = r.int("tool_uses")
        self.totalTokens = r.int("total_tokens", alt: "totalTokens")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskNotificationUsage {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = durationMs { d["duration_ms"] = v }
        if let v = toolUses { d["tool_uses"] = v }
        if let v = totalTokens { d["total_tokens"] = v }
        return d
    }
}

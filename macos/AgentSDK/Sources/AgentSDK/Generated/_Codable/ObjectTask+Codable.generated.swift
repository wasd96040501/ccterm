import Foundation

extension ObjectTask {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectTask")
        self._raw = r.dict
        self.agentId = r.string("agent_id", alt: "agentId")
        self.canReadOutputFile = r.bool("can_read_output_file", alt: "canReadOutputFile")
        self.content = try? r.decodeArrayIfPresent("content")
        self.description = r.string("description")
        self.isAsync = r.bool("is_async", alt: "isAsync")
        self.outputFile = r.string("output_file", alt: "outputFile")
        self.prompt = r.string("prompt")
        self.status = r.string("status")
        self.totalDurationMs = r.int("total_duration_ms", alt: "totalDurationMs")
        self.totalTokens = r.int("total_tokens", alt: "totalTokens")
        self.totalToolUseCount = r.int("total_tool_use_count", alt: "totalToolUseCount")
        self.usage = r.decodeIfPresent("usage")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectTask {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = agentId { d["agent_id"] = v }
        if let v = canReadOutputFile { d["can_read_output_file"] = v }
        if let v = content { d["content"] = v.map { $0.toTypedJSON() } }
        if let v = description { d["description"] = v }
        if let v = isAsync { d["is_async"] = v }
        if let v = outputFile { d["output_file"] = v }
        if let v = prompt { d["prompt"] = v }
        if let v = status { d["status"] = v }
        if let v = totalDurationMs { d["total_duration_ms"] = v }
        if let v = totalTokens { d["total_tokens"] = v }
        if let v = totalToolUseCount { d["total_tool_use_count"] = v }
        if let v = usage { d["usage"] = v.toTypedJSON() }
        return d
    }
}

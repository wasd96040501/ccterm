import Foundation

extension ErrorDuringExecutionUsage {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ErrorDuringExecutionUsage")
        self._raw = r.dict
        self.cacheCreation = r.decodeIfPresent("cache_creation")
        self.cacheCreationInputTokens = r.int("cache_creation_input_tokens", alt: "cacheCreationInputTokens")
        self.cacheReadInputTokens = r.int("cache_read_input_tokens", alt: "cacheReadInputTokens")
        self.inferenceGeo = r.string("inference_geo")
        self.inputTokens = r.int("input_tokens", alt: "inputTokens")
        self.iterations = r.rawArray("iterations")
        self.outputTokens = r.int("output_tokens", alt: "outputTokens")
        self.serverToolUse = r.decodeIfPresent("server_tool_use")
        self.serviceTier = r.string("service_tier")
        self.speed = r.string("speed")
    }

    public func toJSON() -> Any { _raw }
}

extension ErrorDuringExecutionUsage {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = cacheCreation { d["cache_creation"] = v.toTypedJSON() }
        if let v = cacheCreationInputTokens { d["cache_creation_input_tokens"] = v }
        if let v = cacheReadInputTokens { d["cache_read_input_tokens"] = v }
        if let v = inferenceGeo { d["inference_geo"] = v }
        if let v = inputTokens { d["input_tokens"] = v }
        if let v = iterations { d["iterations"] = v }
        if let v = outputTokens { d["output_tokens"] = v }
        if let v = serverToolUse { d["server_tool_use"] = v.toTypedJSON() }
        if let v = serviceTier { d["service_tier"] = v }
        if let v = speed { d["speed"] = v }
        return d
    }
}

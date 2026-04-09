import Foundation

extension ModelUsageValue {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ModelUsageValue")
        self._raw = r.dict
        self.cacheCreationInputTokens = r.int("cache_creation_input_tokens", alt: "cacheCreationInputTokens")
        self.cacheReadInputTokens = r.int("cache_read_input_tokens", alt: "cacheReadInputTokens")
        self.contextWindow = r.int("context_window", alt: "contextWindow")
        self.costUsd = r.double("cost_usd", alt: "costUSD")
        self.inputTokens = r.int("input_tokens", alt: "inputTokens")
        self.maxOutputTokens = r.int("max_output_tokens", alt: "maxOutputTokens")
        self.outputTokens = r.int("output_tokens", alt: "outputTokens")
        self.webSearchRequests = r.int("web_search_requests", alt: "webSearchRequests")
    }

    public func toJSON() -> Any { _raw }
}

extension ModelUsageValue {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = cacheCreationInputTokens { d["cache_creation_input_tokens"] = v }
        if let v = cacheReadInputTokens { d["cache_read_input_tokens"] = v }
        if let v = contextWindow { d["context_window"] = v }
        if let v = costUsd { d["cost_usd"] = v }
        if let v = inputTokens { d["input_tokens"] = v }
        if let v = maxOutputTokens { d["max_output_tokens"] = v }
        if let v = outputTokens { d["output_tokens"] = v }
        if let v = webSearchRequests { d["web_search_requests"] = v }
        return d
    }
}

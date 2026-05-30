import Foundation

extension ThinkingTokens {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ThinkingTokens")
        self._raw = r.dict
        self.estimatedTokens = r.int("estimated_tokens", alt: "estimatedTokens")
        self.estimatedTokensDelta = r.int("estimated_tokens_delta", alt: "estimatedTokensDelta")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension ThinkingTokens {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = estimatedTokens { d["estimated_tokens"] = v }
        if let v = estimatedTokensDelta { d["estimated_tokens_delta"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

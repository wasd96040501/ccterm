import Foundation

extension CacheCreation {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "CacheCreation")
        self._raw = r.dict
        self.ephemeral1hInputTokens = r.int("ephemeral_1h_input_tokens")
        self.ephemeral5mInputTokens = r.int("ephemeral_5m_input_tokens")
    }

    public func toJSON() -> Any { _raw }
}

extension CacheCreation {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = ephemeral1hInputTokens { d["ephemeral_1h_input_tokens"] = v }
        if let v = ephemeral5mInputTokens { d["ephemeral_5m_input_tokens"] = v }
        return d
    }
}

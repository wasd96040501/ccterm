import Foundation

extension LastPrompt {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "LastPrompt")
        self._raw = r.dict
        self.lastPrompt = r.string("last_prompt", alt: "lastPrompt")
        self.sessionId = r.string("session_id", alt: "sessionId")
    }

    public func toJSON() -> Any { _raw }
}

extension LastPrompt {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = lastPrompt { d["last_prompt"] = v }
        if let v = sessionId { d["session_id"] = v }
        return d
    }
}

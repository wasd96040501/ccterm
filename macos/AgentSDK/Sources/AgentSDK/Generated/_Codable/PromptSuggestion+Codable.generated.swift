import Foundation

extension PromptSuggestion {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "PromptSuggestion")
        self._raw = r.dict
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.suggestion = r.string("suggestion")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension PromptSuggestion {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = sessionId { d["session_id"] = v }
        if let v = suggestion { d["suggestion"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

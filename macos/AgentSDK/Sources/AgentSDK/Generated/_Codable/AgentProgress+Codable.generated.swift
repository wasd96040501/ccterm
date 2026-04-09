import Foundation

extension AgentProgress {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "AgentProgress")
        self._raw = r.dict
        self.agentId = r.string("agent_id", alt: "agentId")
        self.message = r.decodeIfPresent("message")
        self.normalizedMessages = r.rawArray("normalized_messages", alt: "normalizedMessages")
        self.prompt = r.string("prompt")
        self.resume = r.string("resume")
    }

    public func toJSON() -> Any { _raw }
}

extension AgentProgress {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = agentId { d["agent_id"] = v }
        if let v = message { d["message"] = v.toTypedJSON() }
        if let v = normalizedMessages { d["normalized_messages"] = v }
        if let v = prompt { d["prompt"] = v }
        if let v = resume { d["resume"] = v }
        return d
    }
}

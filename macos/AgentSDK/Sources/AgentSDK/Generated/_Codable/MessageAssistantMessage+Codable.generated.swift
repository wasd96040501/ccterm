import Foundation

extension MessageAssistantMessage {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MessageAssistantMessage")
        self._raw = r.dict
        self.content = try? r.decodeArrayIfPresent("content")
        self.contextManagement = r.raw("context_management")
        self.id = r.string("id")
        self.model = r.string("model")
        self.role = r.string("role")
        self.stopReason = r.string("stop_reason")
        self.stopSequence = r.raw("stop_sequence")
        self.`type` = r.string("type")
        self.usage = r.decodeIfPresent("usage")
    }

    public func toJSON() -> Any { _raw }
}

extension MessageAssistantMessage {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v.map { $0.toTypedJSON() } }
        if let v = contextManagement { d["context_management"] = v }
        if let v = id { d["id"] = v }
        if let v = model { d["model"] = v }
        if let v = role { d["role"] = v }
        if let v = stopReason { d["stop_reason"] = v }
        if let v = stopSequence { d["stop_sequence"] = v }
        if let v = `type` { d["type"] = v }
        if let v = usage { d["usage"] = v.toTypedJSON() }
        return d
    }
}

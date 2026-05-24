import Foundation

extension Message2StreamEvent {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Message2StreamEvent")
        self._raw = r.dict
        self.event = r.decodeIfPresent("event")
        self.parentToolUseId = r.string("parent_tool_use_id", alt: "parentToolUseID")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.ttftMs = r.int("ttft_ms", alt: "ttftMs")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension Message2StreamEvent {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = event { d["event"] = v.toTypedJSON() }
        if let v = parentToolUseId { d["parent_tool_use_id"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = ttftMs { d["ttft_ms"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

import Foundation

extension Enqueue {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Enqueue")
        self._raw = r.dict
        self.content = r.string("content")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.timestamp = r.string("timestamp")
    }

    public func toJSON() -> Any { _raw }
}

extension Enqueue {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = timestamp { d["timestamp"] = v }
        return d
    }
}

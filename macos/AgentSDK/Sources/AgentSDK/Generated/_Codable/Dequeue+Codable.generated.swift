import Foundation

extension Dequeue {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Dequeue")
        self._raw = r.dict
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.timestamp = r.string("timestamp")
    }

    public func toJSON() -> Any { _raw }
}

extension Dequeue {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = sessionId { d["session_id"] = v }
        if let v = timestamp { d["timestamp"] = v }
        return d
    }
}

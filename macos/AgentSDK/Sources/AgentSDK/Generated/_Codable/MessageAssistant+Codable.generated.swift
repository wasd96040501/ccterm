import Foundation

extension MessageAssistant {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MessageAssistant")
        self._raw = r.dict
        self.message = r.decodeIfPresent("message")
        self.requestId = r.string("request_id", alt: ["requestID", "requestId"])
        self.timestamp = r.string("timestamp")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension MessageAssistant {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = message { d["message"] = v.toTypedJSON() }
        if let v = requestId { d["request_id"] = v }
        if let v = timestamp { d["timestamp"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

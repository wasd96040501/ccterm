import Foundation

extension ForkedFrom {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ForkedFrom")
        self._raw = r.dict
        self.messageUuid = r.string("message_uuid", alt: "messageUuid")
        self.sessionId = r.string("session_id", alt: "sessionId")
    }

    public func toJSON() -> Any { _raw }
}

extension ForkedFrom {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = messageUuid { d["message_uuid"] = v }
        if let v = sessionId { d["session_id"] = v }
        return d
    }
}

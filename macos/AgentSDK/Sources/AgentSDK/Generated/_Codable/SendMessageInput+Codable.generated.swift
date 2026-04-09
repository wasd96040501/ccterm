import Foundation

extension SendMessageInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "SendMessageInput")
        self._raw = r.dict
        self.approve = r.bool("approve")
        self.content = r.string("content")
        self.message = r.decodeIfPresent("message")
        self.recipient = r.string("recipient")
        self.requestId = r.string("request_id", alt: ["requestID", "requestId"])
        self.summary = r.string("summary")
        self.to = r.string("to")
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension SendMessageInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = approve { d["approve"] = v }
        if let v = content { d["content"] = v }
        if let v = message { d["message"] = v.toTypedJSON() }
        if let v = recipient { d["recipient"] = v }
        if let v = requestId { d["request_id"] = v }
        if let v = summary { d["summary"] = v }
        if let v = to { d["to"] = v }
        if let v = `type` { d["type"] = v }
        return d
    }
}

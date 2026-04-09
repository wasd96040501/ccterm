import Foundation

extension MessageObject {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MessageObject")
        self._raw = r.dict
        self.approve = r.bool("approve")
        self.reason = r.string("reason")
        self.requestId = r.string("request_id", alt: ["requestID", "requestId"])
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension MessageObject {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = approve { d["approve"] = v }
        if let v = reason { d["reason"] = v }
        if let v = requestId { d["request_id"] = v }
        if let v = `type` { d["type"] = v }
        return d
    }
}

import Foundation

extension ObjectSendMessage {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectSendMessage")
        self._raw = r.dict
        self.message = r.string("message")
        self.requestId = r.string("request_id", alt: ["requestID", "requestId"])
        self.routing = r.decodeIfPresent("routing")
        self.success = r.bool("success")
        self.target = r.string("target")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectSendMessage {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = message { d["message"] = v }
        if let v = requestId { d["request_id"] = v }
        if let v = routing { d["routing"] = v.toTypedJSON() }
        if let v = success { d["success"] = v }
        if let v = target { d["target"] = v }
        return d
    }
}

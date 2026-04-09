import Foundation

extension RateLimitEvent {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "RateLimitEvent")
        self._raw = r.dict
        self.rateLimitInfo = r.decodeIfPresent("rate_limit_info")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension RateLimitEvent {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = rateLimitInfo { d["rate_limit_info"] = v.toTypedJSON() }
        if let v = sessionId { d["session_id"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

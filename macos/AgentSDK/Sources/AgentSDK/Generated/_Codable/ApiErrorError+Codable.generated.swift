import Foundation

extension ApiErrorError {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ApiErrorError")
        self._raw = r.dict
        self.cause = r.decodeIfPresent("cause")
        self.headers = r.decodeIfPresent("headers")
        self.requestId = r.raw("request_id", alt: ["requestID", "requestId"])
        self.status = r.int("status")
    }

    public func toJSON() -> Any { _raw }
}

extension ApiErrorError {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = cause { d["cause"] = v.toTypedJSON() }
        if let v = headers { d["headers"] = v.toTypedJSON() }
        if let v = requestId { d["request_id"] = v }
        if let v = status { d["status"] = v }
        return d
    }
}

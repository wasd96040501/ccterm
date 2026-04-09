import Foundation

extension MessageUsageServerToolUse {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MessageUsageServerToolUse")
        self._raw = r.dict
        self.webFetchRequests = r.int("web_fetch_requests")
        self.webSearchRequests = r.int("web_search_requests", alt: "webSearchRequests")
    }

    public func toJSON() -> Any { _raw }
}

extension MessageUsageServerToolUse {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = webFetchRequests { d["web_fetch_requests"] = v }
        if let v = webSearchRequests { d["web_search_requests"] = v }
        return d
    }
}

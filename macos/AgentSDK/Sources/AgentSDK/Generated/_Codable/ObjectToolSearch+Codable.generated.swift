import Foundation

extension ObjectToolSearch {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectToolSearch")
        self._raw = r.dict
        self.matches = r.stringArray("matches")
        self.query = r.string("query")
        self.totalDeferredTools = r.int("total_deferred_tools")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectToolSearch {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = matches { d["matches"] = v }
        if let v = query { d["query"] = v }
        if let v = totalDeferredTools { d["total_deferred_tools"] = v }
        return d
    }
}

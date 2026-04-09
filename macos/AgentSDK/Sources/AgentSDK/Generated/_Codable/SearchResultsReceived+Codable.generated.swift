import Foundation

extension SearchResultsReceived {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "SearchResultsReceived")
        self._raw = r.dict
        self.query = r.string("query")
        self.resultCount = r.int("result_count", alt: "resultCount")
    }

    public func toJSON() -> Any { _raw }
}

extension SearchResultsReceived {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = query { d["query"] = v }
        if let v = resultCount { d["result_count"] = v }
        return d
    }
}

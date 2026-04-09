import Foundation

extension ToolUseToolSearchInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseToolSearchInput")
        self._raw = r.dict
        self.maxResults = r.int("max_results")
        self.query = r.string("query")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseToolSearchInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = maxResults { d["max_results"] = v }
        if let v = query { d["query"] = v }
        return d
    }
}

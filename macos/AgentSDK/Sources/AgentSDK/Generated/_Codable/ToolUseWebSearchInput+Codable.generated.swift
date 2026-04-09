import Foundation

extension ToolUseWebSearchInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseWebSearchInput")
        self._raw = r.dict
        self.allowedDomains = r.stringArray("allowed_domains")
        self.query = r.string("query")
        self.searchQuery = r.string("search_query")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseWebSearchInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = allowedDomains { d["allowed_domains"] = v }
        if let v = query { d["query"] = v }
        if let v = searchQuery { d["search_query"] = v }
        return d
    }
}

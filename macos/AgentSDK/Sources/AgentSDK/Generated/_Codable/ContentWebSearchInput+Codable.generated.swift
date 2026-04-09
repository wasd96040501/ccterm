import Foundation

extension ContentWebSearchInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ContentWebSearchInput")
        self._raw = r.dict
        self.allowedDomains = r.stringArray("allowed_domains")
        self.query = r.string("query")
    }

    public func toJSON() -> Any { _raw }
}

extension ContentWebSearchInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = allowedDomains { d["allowed_domains"] = v }
        if let v = query { d["query"] = v }
        return d
    }
}

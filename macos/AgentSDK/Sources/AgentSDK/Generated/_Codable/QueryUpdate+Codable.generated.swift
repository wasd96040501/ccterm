import Foundation

extension QueryUpdate {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "QueryUpdate")
        self._raw = r.dict
        self.query = r.string("query")
    }

    public func toJSON() -> Any { _raw }
}

extension QueryUpdate {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = query { d["query"] = v }
        return d
    }
}

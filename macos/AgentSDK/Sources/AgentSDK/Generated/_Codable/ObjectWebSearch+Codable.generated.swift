import Foundation

extension ObjectWebSearch {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectWebSearch")
        self._raw = r.dict
        self.durationSeconds = r.double("duration_seconds", alt: "durationSeconds")
        self.query = r.string("query")
        self.results = try? r.decodeArrayIfPresent("results")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectWebSearch {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = durationSeconds { d["duration_seconds"] = v }
        if let v = query { d["query"] = v }
        if let v = results { d["results"] = v.map { $0.toTypedJSON() } }
        return d
    }
}

import Foundation

extension Origin {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Origin")
        self._raw = r.dict
        self.kind = r.string("kind")
    }

    public func toJSON() -> Any { _raw }
}

extension Origin {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = kind { d["kind"] = v }
        return d
    }
}

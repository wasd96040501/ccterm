import Foundation

extension StatusChange {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "StatusChange")
        self._raw = r.dict
        self.from = r.string("from")
        self.to = r.string("to")
    }

    public func toJSON() -> Any { _raw }
}

extension StatusChange {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = from { d["from"] = v }
        if let v = to { d["to"] = v }
        return d
    }
}

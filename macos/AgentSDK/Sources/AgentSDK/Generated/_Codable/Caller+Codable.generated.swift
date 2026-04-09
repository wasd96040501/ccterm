import Foundation

extension Caller {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Caller")
        self._raw = r.dict
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension Caller {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = `type` { d["type"] = v }
        return d
    }
}

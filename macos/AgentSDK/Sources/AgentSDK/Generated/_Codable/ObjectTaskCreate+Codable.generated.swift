import Foundation

extension ObjectTaskCreate {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectTaskCreate")
        self._raw = r.dict
        self.task = r.decodeIfPresent("task")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectTaskCreate {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = task { d["task"] = v.toTypedJSON() }
        return d
    }
}

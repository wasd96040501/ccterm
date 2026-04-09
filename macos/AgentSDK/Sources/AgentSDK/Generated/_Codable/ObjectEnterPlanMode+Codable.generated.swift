import Foundation

extension ObjectEnterPlanMode {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectEnterPlanMode")
        self._raw = r.dict
        self.message = r.string("message")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectEnterPlanMode {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = message { d["message"] = v }
        return d
    }
}

import Foundation

extension ContextManagement {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ContextManagement")
        self._raw = r.dict
        self.appliedEdits = r.rawArray("applied_edits")
    }

    public func toJSON() -> Any { _raw }
}

extension ContextManagement {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = appliedEdits { d["applied_edits"] = v }
        return d
    }
}

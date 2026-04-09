import Foundation

extension AnnotationsValue {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "AnnotationsValue")
        self._raw = r.dict
        self.notes = r.string("notes")
        self.preview = r.string("preview")
    }

    public func toJSON() -> Any { _raw }
}

extension AnnotationsValue {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = notes { d["notes"] = v }
        if let v = preview { d["preview"] = v }
        return d
    }
}

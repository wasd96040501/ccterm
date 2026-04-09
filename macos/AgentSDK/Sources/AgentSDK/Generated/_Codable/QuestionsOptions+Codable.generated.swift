import Foundation

extension QuestionsOptions {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "QuestionsOptions")
        self._raw = r.dict
        self.description = r.string("description")
        self.label = r.string("label")
        self.preview = r.string("preview")
    }

    public func toJSON() -> Any { _raw }
}

extension QuestionsOptions {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = description { d["description"] = v }
        if let v = label { d["label"] = v }
        if let v = preview { d["preview"] = v }
        return d
    }
}

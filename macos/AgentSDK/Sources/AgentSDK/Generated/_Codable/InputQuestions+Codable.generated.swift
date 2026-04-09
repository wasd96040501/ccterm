import Foundation

extension InputQuestions {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "InputQuestions")
        self._raw = r.dict
        self.header = r.string("header")
        self.multiSelect = r.bool("multi_select", alt: "multiSelect")
        self.options = try? r.decodeArrayIfPresent("options")
        self.question = r.string("question")
    }

    public func toJSON() -> Any { _raw }
}

extension InputQuestions {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = header { d["header"] = v }
        if let v = multiSelect { d["multi_select"] = v }
        if let v = options { d["options"] = v.map { $0.toTypedJSON() } }
        if let v = question { d["question"] = v }
        return d
    }
}

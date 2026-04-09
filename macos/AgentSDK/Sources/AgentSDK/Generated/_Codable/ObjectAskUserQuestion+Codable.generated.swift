import Foundation

extension ObjectAskUserQuestion {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectAskUserQuestion")
        self._raw = r.dict
        self.annotations = try? r.decodeMap("annotations")
        self.answers = r.stringDict("answers")
        self.questions = try? r.decodeArrayIfPresent("questions")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectAskUserQuestion {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = annotations { d["annotations"] = v.mapValues { $0.toTypedJSON() } }
        if let v = answers { d["answers"] = v }
        if let v = questions { d["questions"] = v.map { $0.toTypedJSON() } }
        return d
    }
}

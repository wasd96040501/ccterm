import Foundation

extension ToolUseAskUserQuestionInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseAskUserQuestionInput")
        self._raw = r.dict
        self.questions = try? r.decodeArrayIfPresent("questions")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseAskUserQuestionInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = questions { d["questions"] = v.map { $0.toTypedJSON() } }
        return d
    }
}

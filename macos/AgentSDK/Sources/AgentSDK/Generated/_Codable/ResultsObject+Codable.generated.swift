import Foundation

extension ResultsObject {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ResultsObject")
        self._raw = r.dict
        self.content = try? r.decodeArrayIfPresent("content")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
    }

    public func toJSON() -> Any { _raw }
}

extension ResultsObject {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v.map { $0.toTypedJSON() } }
        if let v = toolUseId { d["tool_use_id"] = v }
        return d
    }
}

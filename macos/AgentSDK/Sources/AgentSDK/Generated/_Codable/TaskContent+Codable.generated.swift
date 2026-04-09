import Foundation

extension TaskContent {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskContent")
        self._raw = r.dict
        self.text = r.string("text")
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskContent {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = text { d["text"] = v }
        if let v = `type` { d["type"] = v }
        return d
    }
}

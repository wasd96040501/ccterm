import Foundation

extension ToolUseGlob {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseGlob")
        self._raw = r.dict
        self.caller = r.decodeIfPresent("caller")
        self.id = r.string("id")
        self.input = r.decodeIfPresent("input")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseGlob {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = caller { d["caller"] = v.toTypedJSON() }
        if let v = id { d["id"] = v }
        if let v = input { d["input"] = v.toTypedJSON() }
        return d
    }
}

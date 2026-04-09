import Foundation

extension ToolUseGlobInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseGlobInput")
        self._raw = r.dict
        self.path = r.string("path")
        self.pattern = r.string("pattern")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseGlobInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = path { d["path"] = v }
        if let v = pattern { d["pattern"] = v }
        return d
    }
}

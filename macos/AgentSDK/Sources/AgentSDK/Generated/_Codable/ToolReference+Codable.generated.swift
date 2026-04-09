import Foundation

extension ToolReference {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolReference")
        self._raw = r.dict
        self.toolName = r.string("tool_name", alt: "toolName")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolReference {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = toolName { d["tool_name"] = v }
        return d
    }
}

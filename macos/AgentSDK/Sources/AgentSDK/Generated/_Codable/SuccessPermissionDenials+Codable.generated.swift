import Foundation

extension SuccessPermissionDenials {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "SuccessPermissionDenials")
        self._raw = r.dict
        self.toolInput = r.decodeIfPresent("tool_input")
        self.toolName = r.string("tool_name", alt: "toolName")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
    }

    public func toJSON() -> Any { _raw }
}

extension SuccessPermissionDenials {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = toolInput { d["tool_input"] = v.toTypedJSON() }
        if let v = toolName { d["tool_name"] = v }
        if let v = toolUseId { d["tool_use_id"] = v }
        return d
    }
}

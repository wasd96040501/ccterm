import Foundation

extension ItemToolResult {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ItemToolResult")
        self._raw = r.dict
        self.content = r.decodeIfPresent("content")
        self.isError = r.bool("is_error")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
    }

    public func toJSON() -> Any { _raw }
}

extension ItemToolResult {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = content { d["content"] = v.toTypedJSON() }
        if let v = isError { d["is_error"] = v }
        if let v = toolUseId { d["tool_use_id"] = v }
        return d
    }
}

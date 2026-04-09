import Foundation

extension ContentToolResultContentItem {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ContentToolResultContentItem")
        self._raw = r.dict
        self.toolName = r.string("tool_name", alt: "toolName")
        self.`type` = r.string("type")
    }

    public func toJSON() -> Any { _raw }
}

extension ContentToolResultContentItem {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = toolName { d["tool_name"] = v }
        if let v = `type` { d["type"] = v }
        return d
    }
}

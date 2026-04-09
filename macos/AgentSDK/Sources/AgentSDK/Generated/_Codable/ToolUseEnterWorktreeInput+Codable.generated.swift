import Foundation

extension ToolUseEnterWorktreeInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseEnterWorktreeInput")
        self._raw = r.dict
        self.name = r.string("name")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseEnterWorktreeInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = name { d["name"] = v }
        return d
    }
}

import Foundation

extension ToolUseExitWorktreeInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseExitWorktreeInput")
        self._raw = r.dict
        self.action = r.string("action")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseExitWorktreeInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = action { d["action"] = v }
        return d
    }
}

import Foundation

extension ToolUseTodoWriteInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseTodoWriteInput")
        self._raw = r.dict
        self.todos = r.decodeIfPresent("todos")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseTodoWriteInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = todos { d["todos"] = v.toTypedJSON() }
        return d
    }
}

import Foundation

extension ObjectTodoWrite {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectTodoWrite")
        self._raw = r.dict
        self.newTodos = try? r.decodeArrayIfPresent("new_todos", alt: "newTodos")
        self.oldTodos = try? r.decodeArrayIfPresent("old_todos", alt: "oldTodos")
        self.verificationNudgeNeeded = r.bool("verification_nudge_needed", alt: "verificationNudgeNeeded")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectTodoWrite {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = newTodos { d["new_todos"] = v.map { $0.toTypedJSON() } }
        if let v = oldTodos { d["old_todos"] = v.map { $0.toTypedJSON() } }
        if let v = verificationNudgeNeeded { d["verification_nudge_needed"] = v }
        return d
    }
}

import Foundation

extension TaskInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TaskInput")
        self._raw = r.dict
        self.description = r.string("description")
        self.model = r.string("model")
        self.prompt = r.string("prompt")
        self.resume = r.string("resume")
        self.runInBackground = r.bool("run_in_background")
        self.subagentType = r.string("subagent_type")
    }

    public func toJSON() -> Any { _raw }
}

extension TaskInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = description { d["description"] = v }
        if let v = model { d["model"] = v }
        if let v = prompt { d["prompt"] = v }
        if let v = resume { d["resume"] = v }
        if let v = runInBackground { d["run_in_background"] = v }
        if let v = subagentType { d["subagent_type"] = v }
        return d
    }
}

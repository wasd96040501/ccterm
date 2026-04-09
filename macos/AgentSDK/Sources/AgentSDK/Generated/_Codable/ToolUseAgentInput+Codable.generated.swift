import Foundation

extension ToolUseAgentInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseAgentInput")
        self._raw = r.dict
        self.description = r.string("description")
        self.isolation = r.string("isolation")
        self.mode = r.string("mode")
        self.model = r.string("model")
        self.name = r.string("name")
        self.prompt = r.string("prompt")
        self.resume = r.string("resume")
        self.runInBackground = r.bool("run_in_background")
        self.subagentType = r.string("subagent_type")
        self.teamName = r.string("team_name", alt: "teamName")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseAgentInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = description { d["description"] = v }
        if let v = isolation { d["isolation"] = v }
        if let v = mode { d["mode"] = v }
        if let v = model { d["model"] = v }
        if let v = name { d["name"] = v }
        if let v = prompt { d["prompt"] = v }
        if let v = resume { d["resume"] = v }
        if let v = runInBackground { d["run_in_background"] = v }
        if let v = subagentType { d["subagent_type"] = v }
        if let v = teamName { d["team_name"] = v }
        return d
    }
}

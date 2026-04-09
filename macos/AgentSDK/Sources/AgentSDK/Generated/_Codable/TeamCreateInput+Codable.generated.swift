import Foundation

extension TeamCreateInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TeamCreateInput")
        self._raw = r.dict
        self.agentType = r.string("agent_type", alt: "agentType")
        self.description = r.string("description")
        self.teamName = r.string("team_name", alt: "teamName")
    }

    public func toJSON() -> Any { _raw }
}

extension TeamCreateInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = agentType { d["agent_type"] = v }
        if let v = description { d["description"] = v }
        if let v = teamName { d["team_name"] = v }
        return d
    }
}

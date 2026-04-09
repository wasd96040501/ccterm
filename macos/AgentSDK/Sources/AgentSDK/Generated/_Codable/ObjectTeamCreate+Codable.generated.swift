import Foundation

extension ObjectTeamCreate {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectTeamCreate")
        self._raw = r.dict
        self.leadAgentId = r.string("lead_agent_id")
        self.teamFilePath = r.string("team_file_path")
        self.teamName = r.string("team_name", alt: "teamName")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectTeamCreate {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = leadAgentId { d["lead_agent_id"] = v }
        if let v = teamFilePath { d["team_file_path"] = v }
        if let v = teamName { d["team_name"] = v }
        return d
    }
}

import Foundation

extension Message2Progress {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Message2Progress")
        self._raw = r.dict
        self.agentId = r.string("agent_id", alt: "agentId")
        self.cwd = r.string("cwd")
        self.data = r.decodeIfPresent("data")
        self.entrypoint = r.string("entrypoint")
        self.forkedFrom = r.decodeIfPresent("forked_from", alt: "forkedFrom")
        self.gitBranch = r.string("git_branch", alt: "gitBranch")
        self.isSidechain = r.bool("is_sidechain", alt: "isSidechain")
        self.parentToolUseId = r.string("parent_tool_use_id", alt: "parentToolUseID")
        self.parentUuid = r.string("parent_uuid", alt: "parentUuid")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.slug = r.string("slug")
        self.teamName = r.string("team_name", alt: "teamName")
        self.timestamp = r.string("timestamp")
        self.toolUseId = r.string("tool_use_id", alt: "toolUseID")
        self.userType = r.string("user_type", alt: "userType")
        self.uuid = r.string("uuid")
        self.version = r.string("version")
    }

    public func toJSON() -> Any { _raw }
}

extension Message2Progress {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = agentId { d["agent_id"] = v }
        if let v = cwd { d["cwd"] = v }
        if let v = data { d["data"] = v.toTypedJSON() }
        if let v = entrypoint { d["entrypoint"] = v }
        if let v = forkedFrom { d["forked_from"] = v.toTypedJSON() }
        if let v = gitBranch { d["git_branch"] = v }
        if let v = isSidechain { d["is_sidechain"] = v }
        if let v = parentToolUseId { d["parent_tool_use_id"] = v }
        if let v = parentUuid { d["parent_uuid"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = slug { d["slug"] = v }
        if let v = teamName { d["team_name"] = v }
        if let v = timestamp { d["timestamp"] = v }
        if let v = toolUseId { d["tool_use_id"] = v }
        if let v = userType { d["user_type"] = v }
        if let v = uuid { d["uuid"] = v }
        if let v = version { d["version"] = v }
        return d
    }
}

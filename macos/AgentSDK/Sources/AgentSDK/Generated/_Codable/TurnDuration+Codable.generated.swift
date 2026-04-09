import Foundation

extension TurnDuration {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TurnDuration")
        self._raw = r.dict
        self.cwd = r.string("cwd")
        self.durationMs = r.int("duration_ms", alt: "durationMs")
        self.entrypoint = r.string("entrypoint")
        self.forkedFrom = r.decodeIfPresent("forked_from", alt: "forkedFrom")
        self.gitBranch = r.string("git_branch", alt: "gitBranch")
        self.isMeta = r.bool("is_meta", alt: "isMeta")
        self.isSidechain = r.bool("is_sidechain", alt: "isSidechain")
        self.messageCount = r.int("message_count", alt: "messageCount")
        self.parentUuid = r.string("parent_uuid", alt: "parentUuid")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.slug = r.string("slug")
        self.teamName = r.string("team_name", alt: "teamName")
        self.timestamp = r.string("timestamp")
        self.userType = r.string("user_type", alt: "userType")
        self.uuid = r.string("uuid")
        self.version = r.string("version")
    }

    public func toJSON() -> Any { _raw }
}

extension TurnDuration {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = cwd { d["cwd"] = v }
        if let v = durationMs { d["duration_ms"] = v }
        if let v = entrypoint { d["entrypoint"] = v }
        if let v = forkedFrom { d["forked_from"] = v.toTypedJSON() }
        if let v = gitBranch { d["git_branch"] = v }
        if let v = isMeta { d["is_meta"] = v }
        if let v = isSidechain { d["is_sidechain"] = v }
        if let v = messageCount { d["message_count"] = v }
        if let v = parentUuid { d["parent_uuid"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = slug { d["slug"] = v }
        if let v = teamName { d["team_name"] = v }
        if let v = timestamp { d["timestamp"] = v }
        if let v = userType { d["user_type"] = v }
        if let v = uuid { d["uuid"] = v }
        if let v = version { d["version"] = v }
        return d
    }
}

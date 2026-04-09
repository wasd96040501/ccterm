import Foundation

extension CompactBoundary {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "CompactBoundary")
        self._raw = r.dict
        self.compactMetadata = r.decodeIfPresent("compact_metadata", alt: "compactMetadata")
        self.content = r.string("content")
        self.cwd = r.string("cwd")
        self.gitBranch = r.string("git_branch", alt: "gitBranch")
        self.isMeta = r.bool("is_meta", alt: "isMeta")
        self.isSidechain = r.bool("is_sidechain", alt: "isSidechain")
        self.level = r.string("level")
        self.logicalParentUuid = r.string("logical_parent_uuid", alt: "logicalParentUuid")
        self.parentUuid = r.raw("parent_uuid", alt: "parentUuid")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.slug = r.string("slug")
        self.timestamp = r.string("timestamp")
        self.userType = r.string("user_type", alt: "userType")
        self.uuid = r.string("uuid")
        self.version = r.string("version")
    }

    public func toJSON() -> Any { _raw }
}

extension CompactBoundary {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = compactMetadata { d["compact_metadata"] = v.toTypedJSON() }
        if let v = content { d["content"] = v }
        if let v = cwd { d["cwd"] = v }
        if let v = gitBranch { d["git_branch"] = v }
        if let v = isMeta { d["is_meta"] = v }
        if let v = isSidechain { d["is_sidechain"] = v }
        if let v = level { d["level"] = v }
        if let v = logicalParentUuid { d["logical_parent_uuid"] = v }
        if let v = parentUuid { d["parent_uuid"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = slug { d["slug"] = v }
        if let v = timestamp { d["timestamp"] = v }
        if let v = userType { d["user_type"] = v }
        if let v = uuid { d["uuid"] = v }
        if let v = version { d["version"] = v }
        return d
    }
}

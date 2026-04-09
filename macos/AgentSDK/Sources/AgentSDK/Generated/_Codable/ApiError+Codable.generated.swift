import Foundation

extension ApiError {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ApiError")
        self._raw = r.dict
        self.cause = r.decodeIfPresent("cause")
        self.cwd = r.string("cwd")
        self.entrypoint = r.string("entrypoint")
        self.error = r.decodeIfPresent("error")
        self.gitBranch = r.string("git_branch", alt: "gitBranch")
        self.isSidechain = r.bool("is_sidechain", alt: "isSidechain")
        self.level = r.string("level")
        self.maxRetries = r.int("max_retries", alt: "maxRetries")
        self.parentUuid = r.string("parent_uuid", alt: "parentUuid")
        self.retryAttempt = r.int("retry_attempt", alt: "retryAttempt")
        self.retryInMs = r.double("retry_in_ms", alt: "retryInMs")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.slug = r.string("slug")
        self.timestamp = r.string("timestamp")
        self.userType = r.string("user_type", alt: "userType")
        self.uuid = r.string("uuid")
        self.version = r.string("version")
    }

    public func toJSON() -> Any { _raw }
}

extension ApiError {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = cause { d["cause"] = v.toTypedJSON() }
        if let v = cwd { d["cwd"] = v }
        if let v = entrypoint { d["entrypoint"] = v }
        if let v = error { d["error"] = v.toTypedJSON() }
        if let v = gitBranch { d["git_branch"] = v }
        if let v = isSidechain { d["is_sidechain"] = v }
        if let v = level { d["level"] = v }
        if let v = maxRetries { d["max_retries"] = v }
        if let v = parentUuid { d["parent_uuid"] = v }
        if let v = retryAttempt { d["retry_attempt"] = v }
        if let v = retryInMs { d["retry_in_ms"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = slug { d["slug"] = v }
        if let v = timestamp { d["timestamp"] = v }
        if let v = userType { d["user_type"] = v }
        if let v = uuid { d["uuid"] = v }
        if let v = version { d["version"] = v }
        return d
    }
}

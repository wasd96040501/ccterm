import Foundation

extension Message2User {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Message2User")
        self._raw = r.dict
        self.agentId = r.string("agent_id", alt: "agentId")
        self.cwd = r.string("cwd")
        self.entrypoint = r.string("entrypoint")
        self.forkedFrom = r.decodeIfPresent("forked_from", alt: "forkedFrom")
        self.gitBranch = r.string("git_branch", alt: "gitBranch")
        self.imagePasteIds = r.intArray("image_paste_ids", alt: "imagePasteIds")
        self.isCompactSummary = r.bool("is_compact_summary", alt: "isCompactSummary")
        self.isMeta = r.bool("is_meta", alt: "isMeta")
        self.isSidechain = r.bool("is_sidechain", alt: "isSidechain")
        self.isSynthetic = r.bool("is_synthetic", alt: "isSynthetic")
        self.isVisibleInTranscriptOnly = r.bool("is_visible_in_transcript_only", alt: "isVisibleInTranscriptOnly")
        self.message = r.decodeIfPresent("message")
        self.origin = r.decodeIfPresent("origin")
        self.parentToolUseId = r.string("parent_tool_use_id", alt: "parentToolUseID")
        self.parentUuid = r.string("parent_uuid", alt: "parentUuid")
        self.permissionMode = r.string("permission_mode", alt: "permissionMode")
        self.planContent = r.string("plan_content", alt: "planContent")
        self.promptId = r.string("prompt_id", alt: "promptId")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.slug = r.string("slug")
        self.sourceToolAssistantUuid = r.string("source_tool_assistant_uuid", alt: "sourceToolAssistantUUID")
        self.sourceToolUseId = r.string("source_tool_use_id", alt: "sourceToolUseID")
        self.teamName = r.string("team_name", alt: "teamName")
        self.timestamp = r.string("timestamp")
        self.todos = r.rawArray("todos")
        self.toolUseResult = r.decodeIfPresent("tool_use_result", alt: "toolUseResult")
        self.userType = r.string("user_type", alt: "userType")
        self.uuid = r.string("uuid")
        self.version = r.string("version")
    }

    public func toJSON() -> Any { _raw }
}

extension Message2User {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = agentId { d["agent_id"] = v }
        if let v = cwd { d["cwd"] = v }
        if let v = entrypoint { d["entrypoint"] = v }
        if let v = forkedFrom { d["forked_from"] = v.toTypedJSON() }
        if let v = gitBranch { d["git_branch"] = v }
        if let v = imagePasteIds { d["image_paste_ids"] = v }
        if let v = isCompactSummary { d["is_compact_summary"] = v }
        if let v = isMeta { d["is_meta"] = v }
        if let v = isSidechain { d["is_sidechain"] = v }
        if let v = isSynthetic { d["is_synthetic"] = v }
        if let v = isVisibleInTranscriptOnly { d["is_visible_in_transcript_only"] = v }
        if let v = message { d["message"] = v.toTypedJSON() }
        if let v = origin { d["origin"] = v.toTypedJSON() }
        if let v = parentToolUseId { d["parent_tool_use_id"] = v }
        if let v = parentUuid { d["parent_uuid"] = v }
        if let v = permissionMode { d["permission_mode"] = v }
        if let v = planContent { d["plan_content"] = v }
        if let v = promptId { d["prompt_id"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = slug { d["slug"] = v }
        if let v = sourceToolAssistantUuid { d["source_tool_assistant_uuid"] = v }
        if let v = sourceToolUseId { d["source_tool_use_id"] = v }
        if let v = teamName { d["team_name"] = v }
        if let v = timestamp { d["timestamp"] = v }
        if let v = todos { d["todos"] = v }
        if let v = toolUseResult { d["tool_use_result"] = v.toTypedJSON() }
        if let v = userType { d["user_type"] = v }
        if let v = uuid { d["uuid"] = v }
        if let v = version { d["version"] = v }
        return d
    }
}

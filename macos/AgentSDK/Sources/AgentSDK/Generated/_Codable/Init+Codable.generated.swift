import Foundation

extension Init {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Init")
        self._raw = r.dict
        self.agents = r.stringArray("agents")
        self.apiKeySource = r.string("api_key_source", alt: "apiKeySource")
        self.claudeCodeVersion = r.string("claude_code_version")
        self.cwd = r.string("cwd")
        self.fastModeState = r.string("fast_mode_state")
        self.mcpServers = try? r.decodeArrayIfPresent("mcp_servers")
        self.model = r.string("model")
        self.outputStyle = r.string("output_style")
        self.permissionMode = r.string("permission_mode", alt: "permissionMode")
        self.plugins = try? r.decodeArrayIfPresent("plugins")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.skills = r.stringArray("skills")
        self.slashCommands = r.stringArray("slash_commands")
        self.tools = r.stringArray("tools")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension Init {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = agents { d["agents"] = v }
        if let v = apiKeySource { d["api_key_source"] = v }
        if let v = claudeCodeVersion { d["claude_code_version"] = v }
        if let v = cwd { d["cwd"] = v }
        if let v = fastModeState { d["fast_mode_state"] = v }
        if let v = mcpServers { d["mcp_servers"] = v.map { $0.toTypedJSON() } }
        if let v = model { d["model"] = v }
        if let v = outputStyle { d["output_style"] = v }
        if let v = permissionMode { d["permission_mode"] = v }
        if let v = plugins { d["plugins"] = v.map { $0.toTypedJSON() } }
        if let v = sessionId { d["session_id"] = v }
        if let v = skills { d["skills"] = v }
        if let v = slashCommands { d["slash_commands"] = v }
        if let v = tools { d["tools"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}

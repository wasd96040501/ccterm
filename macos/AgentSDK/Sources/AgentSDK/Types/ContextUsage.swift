import Foundation

// MARK: - ContextUsage

/// Typed view of a `get_context_usage` control response.
///
/// The CLI returns a breakdown of how the model's context window is
/// currently spent: a per-category list (Messages, System tools, …),
/// expandable detail lists (memory files, MCP tools, agents), and the
/// raw window size.
///
/// We deliberately keep the parsing tolerant — unknown fields are
/// preserved on `_raw` so callers can opt in to extra data without us
/// having to teach every variant of the schema. The UI only reads the
/// strongly-typed fields below.
public struct ContextUsage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let categories: [Category]
    public let memoryFiles: [MemoryFile]
    public let mcpTools: [McpTool]
    public let deferredBuiltinTools: [BuiltinTool]
    public let agents: [Agent]
    public let skills: Skills?
    public let slashCommands: SlashCommands?
    public let totalTokens: Int
    public let maxTokens: Int
    public let rawMaxTokens: Int
    public let percentage: Int
    public let model: String?
    public let isAutoCompactEnabled: Bool
    public let autoCompactThreshold: Int?
    public let apiUsage: ApiUsage?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ContextUsage")
        self._raw = r.dict
        self.categories = try r.decodeArrayIfPresent("categories") ?? []
        self.memoryFiles = try r.decodeArrayIfPresent("memoryFiles") ?? []
        self.mcpTools = try r.decodeArrayIfPresent("mcpTools") ?? []
        self.deferredBuiltinTools = try r.decodeArrayIfPresent("deferredBuiltinTools") ?? []
        self.agents = try r.decodeArrayIfPresent("agents") ?? []
        self.skills = r.decodeIfPresent("skills")
        self.slashCommands = r.decodeIfPresent("slashCommands")
        self.totalTokens = r.int("totalTokens") ?? 0
        self.maxTokens = r.int("maxTokens") ?? 0
        self.rawMaxTokens = r.int("rawMaxTokens") ?? 0
        self.percentage = r.int("percentage") ?? 0
        self.model = r.string("model")
        self.isAutoCompactEnabled = r.bool("isAutoCompactEnabled") ?? false
        self.autoCompactThreshold = r.int("autoCompactThreshold")
        self.apiUsage = r.decodeIfPresent("apiUsage")
    }

    public func toJSON() -> Any { _raw }

    // MARK: - Nested types

    public struct Category: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let name: String
        public let tokens: Int
        public let color: String?
        public let isDeferred: Bool

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.Category")
            self._raw = r.dict
            self.name = try r.need("name")
            self.tokens = r.int("tokens") ?? 0
            self.color = r.string("color")
            self.isDeferred = r.bool("isDeferred") ?? false
        }

        public func toJSON() -> Any { _raw }
    }

    public struct MemoryFile: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let path: String
        public let type: String?
        public let tokens: Int

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.MemoryFile")
            self._raw = r.dict
            self.path = try r.need("path")
            self.type = r.string("type")
            self.tokens = r.int("tokens") ?? 0
        }

        public func toJSON() -> Any { _raw }
    }

    public struct McpTool: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let name: String
        public let serverName: String
        public let tokens: Int
        public let isLoaded: Bool?

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.McpTool")
            self._raw = r.dict
            self.name = try r.need("name")
            self.serverName = r.string("serverName") ?? ""
            self.tokens = r.int("tokens") ?? 0
            self.isLoaded = r.bool("isLoaded")
        }

        public func toJSON() -> Any { _raw }
    }

    public struct BuiltinTool: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let name: String
        public let tokens: Int
        public let isLoaded: Bool

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.BuiltinTool")
            self._raw = r.dict
            self.name = try r.need("name")
            self.tokens = r.int("tokens") ?? 0
            self.isLoaded = r.bool("isLoaded") ?? false
        }

        public func toJSON() -> Any { _raw }
    }

    public struct Agent: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let agentType: String
        public let source: String?
        public let tokens: Int

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.Agent")
            self._raw = r.dict
            self.agentType = try r.need("agentType")
            self.source = r.string("source")
            self.tokens = r.int("tokens") ?? 0
        }

        public func toJSON() -> Any { _raw }
    }

    public struct Skills: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let totalSkills: Int
        public let includedSkills: Int
        public let tokens: Int

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.Skills")
            self._raw = r.dict
            self.totalSkills = r.int("totalSkills") ?? 0
            self.includedSkills = r.int("includedSkills") ?? 0
            self.tokens = r.int("tokens") ?? 0
        }

        public func toJSON() -> Any { _raw }
    }

    public struct SlashCommands: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let totalCommands: Int
        public let includedCommands: Int
        public let tokens: Int

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.SlashCommands")
            self._raw = r.dict
            self.totalCommands = r.int("totalCommands") ?? 0
            self.includedCommands = r.int("includedCommands") ?? 0
            self.tokens = r.int("tokens") ?? 0
        }

        public func toJSON() -> Any { _raw }
    }

    public struct ApiUsage: JSONParseable, UnknownStrippable {
        public let _raw: [String: Any]
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheCreationInputTokens: Int
        public let cacheReadInputTokens: Int

        public init(json: Any) throws {
            let r = try JSONReader(json, context: "ContextUsage.ApiUsage")
            self._raw = r.dict
            self.inputTokens = r.int("input_tokens") ?? 0
            self.outputTokens = r.int("output_tokens") ?? 0
            self.cacheCreationInputTokens = r.int("cache_creation_input_tokens") ?? 0
            self.cacheReadInputTokens = r.int("cache_read_input_tokens") ?? 0
        }

        public func toJSON() -> Any { _raw }
    }
}

// MARK: - ContextUsageOutcome

/// Result of `Session.getContextUsage`.
///
/// `unsupported` is the back-compat bucket: it means we never heard back
/// from the CLI within the timeout window (old CLI, or one stuck on
/// something else). The UI should treat it as "feature missing" — not as
/// an error to surface to the user.
public enum ContextUsageOutcome {
    case usage(ContextUsage)
    case unsupported
    case sdkError(String)

    public var usage: ContextUsage? {
        if case .usage(let u) = self { return u }
        return nil
    }
}

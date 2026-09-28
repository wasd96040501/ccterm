import Foundation

/// How the context window is currently spent (``Session/contextUsage()``):
/// per-category totals plus the itemized memory files, tools, agents,
/// skills and commands behind them.
public struct ContextUsage: Sendable, Equatable {
    public var categories: [Category]
    public var memoryFiles: [MemoryFile]
    public var mcpTools: [MCPTool]
    /// Built-in tools whose schemas load on demand.
    public var deferredBuiltinTools: [BuiltinTool]
    public var agents: [Agent]
    public var skills: Skills?
    public var slashCommands: SlashCommands?
    public var totalTokens: Int
    /// The usable window (after any reserved output space).
    public var maxTokens: Int
    /// The model's full window.
    public var rawMaxTokens: Int
    public var percentage: Int
    public var model: String?
    public var isAutoCompactEnabled: Bool
    public var autoCompactThreshold: Int?
    /// Token counts of the last API call, when there was one.
    public var apiUsage: Usage?

    public struct Category: Sendable, Equatable {
        public var name: String
        public var tokens: Int
        /// A theme color name the CLI uses for this category.
        public var color: String?
        public var isDeferred: Bool
    }

    public struct MemoryFile: Sendable, Equatable {
        public var path: String
        /// `Project`, `User`, `Local`, …
        public var type: String?
        public var tokens: Int
    }

    public struct MCPTool: Sendable, Equatable {
        public var name: String
        public var serverName: String
        public var tokens: Int
        public var isLoaded: Bool?
    }

    public struct BuiltinTool: Sendable, Equatable {
        public var name: String
        public var tokens: Int
        public var isLoaded: Bool
    }

    public struct Agent: Sendable, Equatable {
        public var agentType: String
        public var source: String?
        public var tokens: Int
    }

    public struct Skills: Sendable, Equatable {
        public var totalSkills: Int
        public var includedSkills: Int
        public var tokens: Int
    }

    public struct SlashCommands: Sendable, Equatable {
        public var totalCommands: Int
        public var includedCommands: Int
        public var tokens: Int
    }
}

// MARK: - Decodable

extension ContextUsage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        categories = c.lenientArray(Category.self, "categories") ?? []
        memoryFiles = c.lenientArray(MemoryFile.self, "memoryFiles") ?? []
        mcpTools = c.lenientArray(MCPTool.self, "mcpTools") ?? []
        deferredBuiltinTools = c.lenientArray(BuiltinTool.self, "deferredBuiltinTools") ?? []
        agents = c.lenientArray(Agent.self, "agents") ?? []
        skills = c.lenient(Skills.self, "skills")
        slashCommands = c.lenient(SlashCommands.self, "slashCommands")
        totalTokens = c.lenientInt("totalTokens") ?? 0
        maxTokens = c.lenientInt("maxTokens") ?? 0
        rawMaxTokens = c.lenientInt("rawMaxTokens") ?? maxTokens
        percentage = c.lenientInt("percentage") ?? 0
        model = c.lenient(String.self, "model")
        isAutoCompactEnabled = c.lenientBool("isAutoCompactEnabled") ?? false
        autoCompactThreshold = c.lenientInt("autoCompactThreshold")
        apiUsage = c.lenient(Usage.self, "apiUsage")
    }
}

extension ContextUsage.Category: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        name = try c.required(String.self, "name")
        tokens = c.lenientInt("tokens") ?? 0
        color = c.lenient(String.self, "color")
        isDeferred = c.lenientBool("isDeferred") ?? false
    }
}

extension ContextUsage.MemoryFile: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        path = try c.required(String.self, "path")
        type = c.lenient(String.self, "type")
        tokens = c.lenientInt("tokens") ?? 0
    }
}

extension ContextUsage.MCPTool: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        name = try c.required(String.self, "name")
        serverName = c.lenient(String.self, "serverName") ?? ""
        tokens = c.lenientInt("tokens") ?? 0
        isLoaded = c.lenientBool("isLoaded")
    }
}

extension ContextUsage.BuiltinTool: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        name = try c.required(String.self, "name")
        tokens = c.lenientInt("tokens") ?? 0
        isLoaded = c.lenientBool("isLoaded") ?? false
    }
}

extension ContextUsage.Agent: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        agentType = try c.required(String.self, "agentType")
        source = c.lenient(String.self, "source")
        tokens = c.lenientInt("tokens") ?? 0
    }
}

extension ContextUsage.Skills: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        totalSkills = c.lenientInt("totalSkills") ?? 0
        includedSkills = c.lenientInt("includedSkills") ?? 0
        tokens = c.lenientInt("tokens") ?? 0
    }
}

extension ContextUsage.SlashCommands: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        totalCommands = c.lenientInt("totalCommands") ?? 0
        includedCommands = c.lenientInt("includedCommands") ?? 0
        tokens = c.lenientInt("tokens") ?? 0
    }
}

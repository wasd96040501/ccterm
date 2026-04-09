import Foundation

/// 会话启动配置。
public struct SessionConfiguration {
    /// CLI 的工作目录。对应 `--cwd`。
    public var workingDirectory: URL

    /// 使用的模型名称。nil 使用 CLI 默认值。对应 `--model`。
    public var model: String?

    /// 主模型不可用时的备用模型。对应 `--fallback-model`。
    public var fallbackModel: String?

    /// 权限模式（default/acceptEdits/plan/bypassPermissions/dontAsk）。对应 `--permission-mode`。
    public var permissionMode: PermissionMode?

    /// 指定新会话的 session ID（必须为合法 UUID）。对应 `--session-id`。
    public var sessionId: String?

    /// 恢复已有会话。传 session ID 恢复指定会话，传空字符串打开交互选择器。对应 `--resume`。
    public var resume: String?

    /// 创建 git worktree 隔离。传名称指定 worktree 名，传空字符串自动命名。对应 `--worktree`。
    public var worktree: String?

    /// claude 二进制路径。nil 自动查找（$PATH / ~/.claude/local/）。对应 `--cli-path`。
    public var binaryPath: String?

    /// 系统提示配置。nil 使用 CLI 默认提示。对应 `--system-prompt` / `--append-system-prompt`。
    public var systemPrompt: SystemPromptConfig?

    /// 最大对话轮数，达到后自动结束。对应 `--max-turns`。
    public var maxTurns: Int?

    /// 最大预算（美元），超出后停止。对应 `--max-budget-usd`。
    public var maxBudgetUsd: Double?

    /// 额外允许的工具名称列表。对应 `--allowedTools`。
    public var allowedTools: [String]

    /// 禁止使用的工具名称列表。对应 `--disallowedTools`。
    public var disallowedTools: [String]

    /// 基础工具集配置。nil 使用默认工具集。对应 `--tools`。
    public var tools: ToolsConfig?

    /// 启用的 beta 功能标识列表。对应 `--beta`。
    public var betas: [String]

    /// Thinking（扩展思考）配置。对应 `--thinking`。
    public var thinking: ThinkingConfig?

    /// 最大 thinking tokens。优先使用 `thinking` 配置。对应 `--max-thinking-tokens`。
    public var maxThinkingTokens: Int?

    /// 推理力度（low/medium/high/max）。对应 `--effort`。
    public var effort: Effort?

    /// 结构化输出的 JSON Schema。对应 `--output-format`。
    public var outputFormat: [String: Any]?

    /// MCP 服务器配置（JSON 字符串或文件路径）。对应 `--mcp-config`。
    public var mcpConfig: String?

    /// 内联 settings JSON 或 settings 文件路径。对应 `--settings`。
    public var settings: String?

    /// 额外工作目录列表。对应 `--add-dir`。
    public var addDirs: [String]

    /// 继续当前目录下最近一次的对话。对应 `--continue`。
    public var continueConversation: Bool

    /// resume 时创建新 session ID，而非复用原 ID。需配合 resume 或 continueConversation 使用。对应 `--fork-session`。
    public var forkSession: Bool

    /// 流式输出中包含部分消息（assistant 消息的中间状态）。对应 `--include-partial-messages`。
    public var includePartialMessages: Bool

    /// 加载哪些来源的 settings（user/project/local）。nil 使用默认，空数组不加载任何设置。对应 `--setting-sources`。
    public var settingSources: [String]?

    /// 插件目录路径列表。对应 `--plugin-dir`。
    public var plugins: [String]

    /// 传递给 CLI 子进程的额外环境变量。
    public var env: [String: String]

    /// 用户自定义命令前缀，如 "trae-proxy claude --"。非空时替代默认 claude 二进制。
    public var customCommand: String?

    /// Allows switching to bypass-permissions mode at runtime without enabling it by default. Corresponds to `--allow-dangerously-skip-permissions`.
    public var allowDangerouslySkipPermissions: Bool

    /// 透传给 CLI 的额外命令行参数。
    public var extraArguments: [String]

    /// 原始消息导出目录。设置后，所有 stdout JSONL 行按 session ID 分文件写入该目录。
    public var messageExportDirectory: URL?

    public init(
        workingDirectory: URL,
        model: String? = nil,
        fallbackModel: String? = nil,
        permissionMode: PermissionMode? = nil,
        sessionId: String? = nil,
        resume: String? = nil,
        worktree: String? = nil,
        binaryPath: String? = nil,
        systemPrompt: SystemPromptConfig? = nil,
        maxTurns: Int? = nil,
        maxBudgetUsd: Double? = nil,
        allowedTools: [String] = [],
        disallowedTools: [String] = [],
        tools: ToolsConfig? = nil,
        betas: [String] = [],
        thinking: ThinkingConfig? = nil,
        maxThinkingTokens: Int? = nil,
        effort: Effort? = nil,
        outputFormat: [String: Any]? = nil,
        mcpConfig: String? = nil,
        settings: String? = nil,
        addDirs: [String] = [],
        continueConversation: Bool = false,
        forkSession: Bool = false,
        includePartialMessages: Bool = false,
        settingSources: [String]? = nil,
        plugins: [String] = [],
        customCommand: String? = nil,
        env: [String: String] = [:],
        allowDangerouslySkipPermissions: Bool = false,
        extraArguments: [String] = [],
        messageExportDirectory: URL? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.fallbackModel = fallbackModel
        self.permissionMode = permissionMode
        self.sessionId = sessionId
        self.resume = resume
        self.worktree = worktree
        self.binaryPath = binaryPath
        self.systemPrompt = systemPrompt
        self.maxTurns = maxTurns
        self.maxBudgetUsd = maxBudgetUsd
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.tools = tools
        self.betas = betas
        self.thinking = thinking
        self.maxThinkingTokens = maxThinkingTokens
        self.effort = effort
        self.outputFormat = outputFormat
        self.mcpConfig = mcpConfig
        self.settings = settings
        self.addDirs = addDirs
        self.continueConversation = continueConversation
        self.forkSession = forkSession
        self.includePartialMessages = includePartialMessages
        self.settingSources = settingSources
        self.plugins = plugins
        self.customCommand = customCommand
        self.env = env
        self.allowDangerouslySkipPermissions = allowDangerouslySkipPermissions
        self.extraArguments = extraArguments
        self.messageExportDirectory = messageExportDirectory
    }
}

// MARK: - Supporting Types

public enum SystemPromptConfig {
    /// 自定义系统提示（覆盖默认）。
    case custom(String)
    /// 使用默认提示并追加内容。
    case append(String)
    /// 清空系统提示。
    case empty
}

public enum ToolsConfig {
    /// 自定义工具列表。空数组表示无工具。
    case list([String])
    /// 使用默认工具集（claude_code preset）。
    case `default`
}

public enum ThinkingConfig {
    case adaptive
    case enabled(budgetTokens: Int)
    case disabled
}

public enum Effort: String {
    case low
    case medium
    case high
    case max
}

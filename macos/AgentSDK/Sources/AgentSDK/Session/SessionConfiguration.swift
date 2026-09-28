import Foundation

/// Session launch configuration.
public struct SessionConfiguration: Sendable {
    /// CLI working directory. Maps to `--cwd`.
    public var workingDirectory: URL

    /// Model name. nil uses the CLI default. Maps to `--model`.
    public var model: String?

    /// Fallback model used when the primary model is unavailable. Maps to `--fallback-model`.
    public var fallbackModel: String?

    /// Permission mode (default/acceptEdits/plan/bypassPermissions/dontAsk). Maps to `--permission-mode`.
    public var permissionMode: PermissionMode?

    /// Session ID for the new session (must be a valid UUID). Maps to `--session-id`.
    public var sessionId: String?

    /// Resume an existing session: pass a session ID to resume that one, or an empty string to open the interactive picker. Maps to `--resume`.
    public var resume: String?

    /// Create git worktree isolation. Pass a name, or an empty string to auto-name. Maps to `--worktree`.
    public var worktree: String?

    /// Path to the `claude` binary. nil auto-locates (`$PATH` / `~/.claude/local/`). Maps to `--cli-path`.
    public var binaryPath: String?

    /// System prompt configuration. nil uses the CLI default. Maps to `--system-prompt` / `--append-system-prompt`.
    public var systemPrompt: SystemPromptConfig?

    /// Maximum conversation turns; the session auto-ends when reached. Maps to `--max-turns`.
    public var maxTurns: Int?

    /// Maximum budget in USD; the session stops once exceeded. Maps to `--max-budget-usd`.
    public var maxBudgetUsd: Double?

    /// Extra allowed tool names. Maps to `--allowedTools`.
    public var allowedTools: [String]

    /// Disallowed tool names. Maps to `--disallowedTools`.
    public var disallowedTools: [String]

    /// Base tool set. nil uses the default. Maps to `--tools`.
    public var tools: ToolsConfig?

    /// Enabled beta feature flags. Maps to `--beta`.
    public var betas: [String]

    /// Extended thinking configuration. Maps to `--thinking`.
    public var thinking: ThinkingConfig?

    /// Maximum thinking tokens. Prefers `thinking` over this when both are set. Maps to `--max-thinking-tokens`.
    public var maxThinkingTokens: Int?

    /// Reasoning effort (low/medium/high/max). Maps to `--effort`.
    public var effort: Effort?

    /// JSON Schema the final answer must match; the result arrives as
    /// ``ResultMessage/structuredOutput``. Maps to `--json-schema`.
    public var jsonSchema: JSONValue?

    /// MCP server configuration (JSON string or file path). Maps to `--mcp-config`.
    public var mcpConfig: String?

    /// The session's flag settings layer at launch; change it later with
    /// ``Session/applySettings(_:)``. Unset keys are dropped here: the layer
    /// starts empty. Maps to `--settings`.
    public var settings: Settings

    /// Additional working directories. Maps to `--add-dir`.
    public var addDirs: [String]

    /// Continue the most recent conversation in the current directory. Maps to `--continue`.
    public var continueConversation: Bool

    /// On resume, mint a new session ID instead of reusing the original. Use with `resume` or `continueConversation`. Maps to `--fork-session`.
    public var forkSession: Bool

    /// Stream responses as they are generated: the session also emits
    /// ``Message/streamEvent(_:)`` deltas (and `requesting` statuses) ahead of
    /// each finished block. Maps to `--include-partial-messages`.
    public var includePartialMessages: Bool

    /// Emit a ``Message/promptSuggestion(_:)`` after each turn.
    public var promptSuggestions: Bool

    /// Which settings sources to load (user/project/local). nil = default; empty array loads nothing. Maps to `--setting-sources`.
    public var settingSources: [String]?

    /// Plugin directory paths. Maps to `--plugin-dir`.
    public var plugins: [String]

    /// Extra environment variables passed to the CLI subprocess.
    public var env: [String: String]

    /// When true, the CLI subprocess inherits the parent process's
    /// environment (`ProcessInfo.processInfo.environment`) instead of
    /// spawning a login shell to collect one. Default false.
    ///
    /// Why: `ShellEnvironment.loginEnvironment()` runs `zsh -li -c env`,
    /// which on CI runners costs multiple seconds (path_helper / Homebrew
    /// shellenv / user rc). Set to true when the binary you're launching
    /// doesn't need the user's login PATH (e.g. an explicit `binaryPath`
    /// pointing at a self-contained executable like the UI-test mock CLI).
    public var inheritsParentEnvironment: Bool

    /// Custom command prefix, e.g. `"trae-proxy claude --"`. When non-empty, replaces the default `claude` binary.
    public var customCommand: String?

    /// Allows switching to bypass-permissions mode at runtime without enabling it by default. Maps to `--allow-dangerously-skip-permissions`.
    public var allowDangerouslySkipPermissions: Bool

    /// Extra command-line arguments passed through to the CLI.
    public var extraArguments: [String]

    /// Raw-message export directory. When set, every stdout JSONL line is written here, one file per session ID.
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
        jsonSchema: JSONValue? = nil,
        mcpConfig: String? = nil,
        settings: Settings = Settings(),
        addDirs: [String] = [],
        continueConversation: Bool = false,
        forkSession: Bool = false,
        includePartialMessages: Bool = false,
        promptSuggestions: Bool = false,
        settingSources: [String]? = nil,
        plugins: [String] = [],
        customCommand: String? = nil,
        env: [String: String] = [:],
        inheritsParentEnvironment: Bool = false,
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
        self.jsonSchema = jsonSchema
        self.mcpConfig = mcpConfig
        self.settings = settings
        self.addDirs = addDirs
        self.continueConversation = continueConversation
        self.forkSession = forkSession
        self.includePartialMessages = includePartialMessages
        self.promptSuggestions = promptSuggestions
        self.settingSources = settingSources
        self.plugins = plugins
        self.customCommand = customCommand
        self.env = env
        self.inheritsParentEnvironment = inheritsParentEnvironment
        self.allowDangerouslySkipPermissions = allowDangerouslySkipPermissions
        self.extraArguments = extraArguments
        self.messageExportDirectory = messageExportDirectory
    }
}

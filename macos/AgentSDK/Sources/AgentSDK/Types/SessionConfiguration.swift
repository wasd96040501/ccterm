import Foundation

/// Session launch configuration.
public struct SessionConfiguration {
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

    /// JSON Schema for structured output. Maps to `--output-format`.
    public var outputFormat: [String: Any]?

    /// MCP server configuration (JSON string or file path). Maps to `--mcp-config`.
    public var mcpConfig: String?

    /// Inline settings JSON or path to a settings file. Maps to `--settings`.
    public var settings: String?

    /// Additional working directories. Maps to `--add-dir`.
    public var addDirs: [String]

    /// Continue the most recent conversation in the current directory. Maps to `--continue`.
    public var continueConversation: Bool

    /// On resume, mint a new session ID instead of reusing the original. Use with `resume` or `continueConversation`. Maps to `--fork-session`.
    public var forkSession: Bool

    /// Include partial messages (intermediate assistant states) in the
    /// stream. Maps to `--include-partial-messages`.
    ///
    /// When true, the CLI emits SSE-style `stream_event` envelopes
    /// (`message_start` / `content_block_start` /
    /// `content_block_delta` / `content_block_stop` / `message_delta`
    /// / `message_stop`) interleaved with the regular final envelopes.
    /// These flow on a **separate** callback —
    /// `Session.onStreamEvent` — not `onMessage`. Callers that opt in
    /// must subscribe to `onStreamEvent`; otherwise the deltas land in
    /// the dispatcher and are silently dropped, wasting CLI bandwidth
    /// for no UI effect.
    public var includePartialMessages: Bool

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

    /// Structured launch plan. When non-nil it decides how the CLI subprocess is
    /// spawned and takes precedence over both `customCommand` and `binaryPath`.
    /// nil keeps the existing behavior (`customCommand` if set, else auto-located
    /// `claude`). See `LaunchPlan`.
    public var launchPlan: LaunchPlan?

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
        launchPlan: LaunchPlan? = nil,
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
        self.launchPlan = launchPlan
        self.env = env
        self.inheritsParentEnvironment = inheritsParentEnvironment
        self.allowDangerouslySkipPermissions = allowDangerouslySkipPermissions
        self.extraArguments = extraArguments
        self.messageExportDirectory = messageExportDirectory
    }
}

// MARK: - Supporting Types

/// How the CLI subprocess is launched.
///
/// The SDK stays transport-agnostic: it knows nothing about ssh, proxies, or any
/// remote wrapper. A caller that needs to run `claude` somewhere other than a
/// local binary (e.g. on a remote host over ssh) builds the **complete** argv
/// itself — embedding the claude argument list from
/// `SessionConfiguration.claudeArguments()` wherever it belongs — and hands it
/// over via `.wrapped`. The SDK then just runs `executable` with that argv,
/// owning only the `Process` lifecycle.
public enum LaunchPlan {
    /// Run the `claude` binary directly. `binaryPath` nil → auto-locate
    /// (`$PATH` / `~/.claude/local/`). This is the default behavior.
    case local(binaryPath: String?)

    /// Run `executable` with **exactly** `argv` — no tokenizing, nothing
    /// appended. The caller has already incorporated the claude arguments
    /// (see `SessionConfiguration.claudeArguments()`) into `argv`, e.g. inside
    /// an `ssh … 'env … exec claude <args>'` remote command. Quoting of any
    /// nested shell command is the caller's responsibility, not the SDK's.
    case wrapped(executable: String, argv: [String])
}

public enum SystemPromptConfig {
    /// Custom system prompt that replaces the default.
    case custom(String)
    /// Use the default prompt and append additional text.
    case append(String)
    /// Clear the system prompt entirely.
    case empty
}

public enum ToolsConfig {
    /// Custom tool list. Empty array means no tools.
    case list([String])
    /// Use the default tool set (`claude_code` preset).
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
    case xhigh
    case max
}

// MARK: - CLI argument construction

extension SessionConfiguration {
    /// The argument list the SDK passes to `claude` for this configuration
    /// (stream-json I/O, model, session-id, tools, …).
    ///
    /// Exposed so a `LaunchPlan.wrapped` caller can embed these into a remote
    /// command (e.g. an ssh launch) without the SDK having to know about the
    /// transport. The local launch path uses the same list, so what runs
    /// remotely is byte-for-byte what would run locally.
    public func claudeArguments() -> [String] {
        let config = self
        var args = ["--output-format", "stream-json", "--verbose"]
        args += ["--input-format", "stream-json"]
        args += ["--permission-prompt-tool", "stdio"]
        // Have the CLI echo our stdin user messages back on stdout (preserving our uuid) when
        // they become the current turn. We use this as the local queued -> confirmed signal.
        args += ["--replay-user-messages"]

        // System prompt
        switch config.systemPrompt {
        case .custom(let prompt):
            args += ["--system-prompt", prompt]
        case .append(let text):
            args += ["--append-system-prompt", text]
        case .empty:
            args += ["--system-prompt", ""]
        case nil:
            break
        }

        // Tools
        switch config.tools {
        case .list(let list):
            args += ["--tools", list.isEmpty ? "" : list.joined(separator: ",")]
        case .default:
            args += ["--tools", "default"]
        case nil:
            break
        }

        if !config.allowedTools.isEmpty {
            args += ["--allowedTools", config.allowedTools.joined(separator: ",")]
        }
        if !config.disallowedTools.isEmpty {
            args += ["--disallowedTools", config.disallowedTools.joined(separator: ",")]
        }

        // Model
        if let model = config.model {
            args += ["--model", model]
        }
        if let fallbackModel = config.fallbackModel {
            args += ["--fallback-model", fallbackModel]
        }

        // Limits
        if let maxTurns = config.maxTurns {
            args += ["--max-turns", String(maxTurns)]
        }
        if let maxBudgetUsd = config.maxBudgetUsd {
            args += ["--max-budget-usd", String(maxBudgetUsd)]
        }

        // Permission mode
        if let mode = config.permissionMode {
            args += ["--permission-mode", mode.rawValue]
        }
        if config.allowDangerouslySkipPermissions {
            args += ["--allow-dangerously-skip-permissions"]
        }

        // Session
        if config.continueConversation {
            args += ["--continue"]
        }
        if let sessionId = config.sessionId {
            args += ["--session-id", sessionId]
        }
        if let resume = config.resume {
            if resume.isEmpty {
                args += ["--resume"]
            } else {
                args += ["--resume", resume]
            }
        }

        // Settings & Sandbox
        if let settings = config.settings {
            args += ["--settings", settings]
        }

        // Additional directories
        for dir in config.addDirs {
            args += ["--add-dir", dir]
        }

        // MCP
        if let mcpConfig = config.mcpConfig {
            args += ["--mcp-config", mcpConfig]
        }

        // Streaming options
        if config.includePartialMessages {
            args += ["--include-partial-messages"]
        }
        if config.forkSession {
            args += ["--fork-session"]
        }
        if let worktree = config.worktree {
            if worktree.isEmpty {
                args += ["--worktree"]
            } else {
                args += ["--worktree", worktree]
            }
        }

        // Setting sources
        if let sources = config.settingSources {
            args += ["--setting-sources", sources.joined(separator: ",")]
        }

        // Plugins
        for plugin in config.plugins {
            args += ["--plugin-dir", plugin]
        }

        // Betas
        if !config.betas.isEmpty {
            args += ["--betas", config.betas.joined(separator: ",")]
        }

        // Thinking: thinking config takes precedence over maxThinkingTokens
        var resolvedMaxThinkingTokens = config.maxThinkingTokens
        if let thinking = config.thinking {
            switch thinking {
            case .adaptive:
                if resolvedMaxThinkingTokens == nil {
                    resolvedMaxThinkingTokens = 32_000
                }
            case .enabled(let budgetTokens):
                resolvedMaxThinkingTokens = budgetTokens
            case .disabled:
                resolvedMaxThinkingTokens = 0
            }
        }
        if let tokens = resolvedMaxThinkingTokens {
            args += ["--max-thinking-tokens", String(tokens)]
        }

        // Effort
        if let effort = config.effort {
            args += ["--effort", effort.rawValue]
        }

        // Output format (structured output JSON schema)
        if let outputFormat = config.outputFormat,
            let type = outputFormat["type"] as? String, type == "json_schema",
            let schema = outputFormat["schema"],
            let schemaData = try? JSONSerialization.data(withJSONObject: schema),
            let schemaJSON = String(data: schemaData, encoding: .utf8)
        {
            args += ["--json-schema", schemaJSON]
        }

        args += config.extraArguments
        return args
    }
}

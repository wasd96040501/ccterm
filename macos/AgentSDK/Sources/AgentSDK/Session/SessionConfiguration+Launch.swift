import Foundation

extension SessionConfiguration {
    /// A session in `workingDirectory` started as `launch` starts a one-off
    /// run — the same binary, custom command and environment — with every
    /// session knob at its default.
    public init(workingDirectory: URL, launch: CLIConfiguration) {
        self.init(
            workingDirectory: workingDirectory, binaryPath: launch.binaryPath, customCommand: launch.customCommand,
            env: launch.env, inheritsParentEnvironment: launch.inheritsParentEnvironment)
    }

    /// How to start the CLI for this session. Blocking (the login-shell
    /// environment probe can take seconds); call off the main thread.
    func launch() throws -> CLILaunch {
        try CLILaunch(
            arguments: arguments, workingDirectory: workingDirectory, binaryPath: binaryPath,
            customCommand: customCommand, env: env, inheritsParentEnvironment: inheritsParentEnvironment)
    }

    /// The CLI command line for a stream-json session.
    var arguments: [String] {
        var args = [
            "--output-format", "stream-json", "--verbose",
            "--input-format", "stream-json",
            "--permission-prompt-tool", "stdio",
            // Echo each prompt (with its uuid) as it enters a turn.
            "--replay-user-messages",
        ]

        switch systemPrompt {
        case .custom(let prompt): args += ["--system-prompt", prompt]
        case .append(let text): args += ["--append-system-prompt", text]
        case .empty: args += ["--system-prompt", ""]
        case nil: break
        }

        switch tools {
        case .list(let list): args += ["--tools", list.joined(separator: ",")]
        case .default: args += ["--tools", "default"]
        case nil: break
        }
        if !allowedTools.isEmpty { args += ["--allowedTools", allowedTools.joined(separator: ",")] }
        if !disallowedTools.isEmpty { args += ["--disallowedTools", disallowedTools.joined(separator: ",")] }

        if let model { args += ["--model", model] }
        if let fallbackModel { args += ["--fallback-model", fallbackModel] }
        if let maxTurns { args += ["--max-turns", String(maxTurns)] }
        if let maxBudgetUsd { args += ["--max-budget-usd", String(maxBudgetUsd)] }

        if let permissionMode { args += ["--permission-mode", permissionMode.rawValue] }
        if allowDangerouslySkipPermissions { args += ["--allow-dangerously-skip-permissions"] }

        if continueConversation { args += ["--continue"] }
        if let sessionId { args += ["--session-id", sessionId] }
        if let resume { args += resume.isEmpty ? ["--resume"] : ["--resume", resume] }
        if forkSession { args += ["--fork-session"] }
        if let worktree { args += worktree.isEmpty ? ["--worktree"] : ["--worktree", worktree] }

        if let settings = settings.launchArgument { args += ["--settings", settings] }
        if let settingSources { args += ["--setting-sources", settingSources.joined(separator: ",")] }
        for dir in addDirs { args += ["--add-dir", dir] }
        if let mcpConfig { args += ["--mcp-config", mcpConfig] }
        for plugin in plugins { args += ["--plugin-dir", plugin] }
        if !betas.isEmpty { args += ["--betas", betas.joined(separator: ",")] }

        if includePartialMessages { args += ["--include-partial-messages"] }

        // `thinking` wins over `maxThinkingTokens`.
        var thinkingTokens = maxThinkingTokens
        switch thinking {
        case .adaptive: thinkingTokens = thinkingTokens ?? 32_000
        case .enabled(let budget): thinkingTokens = budget
        case .disabled: thinkingTokens = 0
        case nil: break
        }
        if let thinkingTokens { args += ["--max-thinking-tokens", String(thinkingTokens)] }

        if let effort { args += ["--effort", effort.rawValue] }

        if let jsonSchema, let data = try? JSONEncoder().encode(jsonSchema) {
            args += ["--json-schema", String(decoding: data, as: UTF8.self)]
        }

        return args + extraArguments
    }
}

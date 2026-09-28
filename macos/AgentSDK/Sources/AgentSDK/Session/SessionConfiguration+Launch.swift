import Foundation

extension SessionConfiguration {
    /// Resolves the binary and environment and builds the process. Blocking
    /// (the login-shell environment probe can take seconds); call off the
    /// main thread.
    func makeProcess() throws -> CLIProcess {
        let executable: String
        let finalArguments: [String]
        if let customCommand, !customCommand.isEmpty {
            // Through the user's login shell so aliases, functions and
            // `~`/`$VAR` expansion behave as at a prompt; SDK args ride in "$@".
            (executable, finalArguments) = CustomCommand.shellInvocation(customCommand, sdkArgs: arguments)
        } else {
            guard let resolved = binaryPath ?? BinaryLocator.locate() else { throw AgentSDKError.binaryNotFound }
            executable = resolved
            finalArguments = arguments
        }

        var environment =
            inheritsParentEnvironment
            ? ProcessInfo.processInfo.environment
            : (ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment)
        environment.removeValue(forKey: "CLAUDECODE")
        environment.merge(env) { _, override in override }

        return CLIProcess(
            executable: executable, arguments: finalArguments, workingDirectory: workingDirectory,
            environment: environment)
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

        if let settings { args += ["--settings", settings] }
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

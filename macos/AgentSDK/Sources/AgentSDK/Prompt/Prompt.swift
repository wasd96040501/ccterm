import Foundation

/// One-shot prompt runner. Wraps `claude -p --no-session-persistence --output-format json`.
public enum Prompt {

    /// Runs a one-shot prompt, waits for the process to exit, and returns the result.
    public static func run(
        message: String,
        configuration: PromptConfiguration
    ) async throws -> PromptResult {
        let config = configuration

        return try await Task.detached {
            var sdkArgs: [String] = []
            sdkArgs.append("-p")
            sdkArgs.append("--output-format")
            sdkArgs.append("json")
            sdkArgs.append("--no-session-persistence")

            if let model = config.model {
                sdkArgs.append("--model")
                sdkArgs.append(model)
            }
            if let systemPrompt = config.systemPrompt {
                sdkArgs.append("--system-prompt")
                sdkArgs.append(systemPrompt)
            }
            if let tools = config.tools {
                sdkArgs.append("--tools")
                sdkArgs.append(tools.joined(separator: ","))
            }
            if let jsonSchema = config.jsonSchema {
                sdkArgs.append("--json-schema")
                sdkArgs.append(jsonSchema)
            }
            if config.disableSlashCommands {
                sdkArgs.append("--disable-slash-commands")
            }
            if let effort = config.effort {
                sdkArgs.append("--effort")
                // `ultracode` is not a CLI effort value — launch at xhigh.
                sdkArgs.append(effort == Effort.ultracode.rawValue ? Effort.xhigh.rawValue : effort)
            }

            sdkArgs.append("--")
            sdkArgs.append(message)

            let (executablePath, args) = try resolveLaunch(config: config, sdkArgs: sdkArgs)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = args
            proc.currentDirectoryURL = config.workingDirectory

            var env = ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            for (k, v) in config.env { env[k] = v }
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            let fullCommand = ([executablePath] + args).map { arg in
                arg.contains(" ") ? "\"\(arg)\"" : arg
            }.joined(separator: " ")
            NSLog("[AgentSDK.Prompt] Launch: %@", fullCommand)

            do {
                try proc.run()
            } catch {
                throw AgentSDKError.launchFailed(underlying: error)
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let exitCode = proc.terminationStatus
            guard exitCode == 0 else {
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                throw AgentSDKError.promptFailed(exitCode: exitCode, stderr: stderrText)
            }

            guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
                let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
                throw AgentSDKError.promptFailed(exitCode: 0, stderr: "Invalid JSON output: \(stdoutText.prefix(500))")
            }

            return PromptResult(
                result: json["result"] as? String ?? "",
                structuredOutput: json["structured_output"] as? [String: Any],
                sessionId: json["session_id"] as? String,
                totalCostUsd: json["total_cost_usd"] as? Double,
                durationMs: json["duration_ms"] as? Int,
                raw: json
            )
        }.value
    }

    // MARK: - Private

    /// Resolves the executable and full argument vector for the launch. A custom command
    /// runs through the user's login shell (see `CustomCommand`); otherwise the located
    /// `claude` binary is exec'd directly with `sdkArgs`.
    private static func resolveLaunch(
        config: PromptConfiguration,
        sdkArgs: [String]
    ) throws -> (executablePath: String, arguments: [String]) {
        if let customCommand = config.customCommand, !customCommand.isEmpty {
            return CustomCommand.shellInvocation(customCommand, sdkArgs: sdkArgs)
        }
        guard let resolved = config.binaryPath ?? BinaryLocator.locate() else {
            throw AgentSDKError.binaryNotFound
        }
        return (resolved, sdkArgs)
    }
}

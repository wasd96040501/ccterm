import Foundation

/// 一次性 prompt 执行器。对应 `claude -p --no-session-persistence --output-format json`。
public enum Prompt {

    /// 执行一次性 prompt，等待进程退出后返回结果。
    public static func run(
        message: String,
        configuration: PromptConfiguration
    ) async throws -> PromptResult {
        let config = configuration

        return try await Task.detached {
            let (executablePath, prefixArgs) = try resolveExecutable(config: config)

            var args = prefixArgs
            args.append("-p")
            args.append("--output-format")
            args.append("json")
            args.append("--no-session-persistence")

            if let model = config.model {
                args.append("--model")
                args.append(model)
            }
            if let systemPrompt = config.systemPrompt {
                args.append("--system-prompt")
                args.append(systemPrompt)
            }
            if let tools = config.tools {
                args.append("--tools")
                args.append(tools.joined(separator: ","))
            }
            if let jsonSchema = config.jsonSchema {
                args.append("--json-schema")
                args.append(jsonSchema)
            }

            args.append(message)

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

    /// 解析可执行文件路径和前缀参数（customCommand 拆分后的中间 token）。
    private static func resolveExecutable(
        config: PromptConfiguration
    ) throws -> (executablePath: String, prefixArgs: [String]) {
        if let customCommand = config.customCommand, !customCommand.isEmpty {
            let tokens = customCommand.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard var firstToken = tokens.first else { throw AgentSDKError.binaryNotFound }
            if !firstToken.hasPrefix("/") {
                firstToken = try resolveViaWhich(firstToken)
            }
            return (firstToken, Array(tokens.dropFirst()))
        }

        guard let resolved = config.binaryPath ?? BinaryLocator.locate() else {
            throw AgentSDKError.binaryNotFound
        }
        return (resolved, [])
    }

    private static func resolveViaWhich(_ name: String) throws -> String {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        which.environment = ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try which.run()
        which.waitUntilExit()
        guard which.terminationStatus == 0,
              let resolved = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !resolved.isEmpty else {
            throw AgentSDKError.binaryNotFound
        }
        return resolved
    }
}

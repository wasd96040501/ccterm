import Foundation

/// A session that interacts with the CLI subprocess.
///
/// Usage:
/// ```swift
/// let config = SessionConfiguration(workingDirectory: projectURL)
/// let session = Session(configuration: config)
///
/// session.onMessage = { message in ... }
/// session.onPermissionRequest = { request in return .allow }
/// session.onProcessExit = { code in ... }
///
/// try session.start()
///
/// session.sendMessage("Fix the bug")
///
/// session.setModel("claude-sonnet-4-6")
/// session.interrupt()
/// ```
public final class Session {

    // MARK: - Properties

    public let configuration: SessionConfiguration

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let readQueue = DispatchQueue(label: "com.agent-sdk.read", qos: .userInitiated)
    private let stdinQueue = DispatchQueue(label: "com.agent-sdk.stdin")
    private var pendingPermissions: [String: PermissionRequest] = [:]
    private var pendingControlResponses: [String: ([String: Any]) -> Void] = [:]
    /// Current session ID used as the export file name. Pre-set this before `start()`
    /// so the initialize message does not get written to `unknown.jsonl`.
    public var lastKnownSessionId: String?
    private var exportFileHandle: FileHandle?
    private var exportSessionId: String?
    private let resolver = Message2Resolver()

    public var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Callbacks

    /// CLI requests permission for a tool use. Reply asynchronously via `completion`.
    /// Invoked on `readQueue`; `completion` may be called from any thread.
    public var onPermissionRequest:
        ((_ request: PermissionRequest, _ completion: @escaping (PermissionDecision) -> Void) -> Void)?

    /// CLI cancelled a previous permission request.
    public var onPermissionCancelled: ((_ requestId: String) -> Void)?

    /// CLI requests a hook callback. The return value is sent back to the CLI as-is.
    public var onHookRequest: ((_ request: HookRequest) -> HookResult)?

    /// CLI forwards an MCP message. The return value is sent back to the CLI as-is.
    public var onMCPRequest: ((_ request: MCPRequest) -> MCPResponse)?

    /// CLI requests user input (elicitation). The return value is sent back to the CLI as-is.
    public var onElicitationRequest: ((_ request: ElicitationRequest) -> ElicitationResult)?

    /// A typed message arrived (assistant, user, system, result, ...).
    public var onMessage: ((_ message: Message2) -> Void)?

    public var onStderr: ((_ text: String) -> Void)?

    public var onProcessExit: ((_ exitCode: Int32) -> Void)?

    // MARK: - Lifecycle

    public init(configuration: SessionConfiguration) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    /// Starts the CLI subprocess.
    ///
    /// Binary lookup, environment resolution, and `Process.run()` execute on a
    /// background thread so the caller is not blocked.
    public func start() async throws {
        guard !isRunning else { throw AgentSDKError.alreadyRunning }

        let workingDirectory = configuration.workingDirectory
        let binaryPathOverride = configuration.binaryPath
        let customCommand = configuration.customCommand
        let envOverrides = configuration.env
        let arguments = buildArguments()

        // Run binary lookup, env resolution, and Process.run() off the calling thread.
        let (proc, stdin, stdout, stderr) = try await Task.detached {
            let executablePath: String
            let finalArguments: [String]

            if let customCommand, !customCommand.isEmpty {
                // Custom command prefix: first token is the executable, the rest are prepended to arguments.
                let tokens = customCommand.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard var firstToken = tokens.first else { throw AgentSDKError.binaryNotFound }
                if !firstToken.hasPrefix("/") {
                    let which = Process()
                    which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                    which.arguments = [firstToken]
                    // Use login shell environment so PATH is complete.
                    which.environment = ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment
                    let whichPipe = Pipe()
                    which.standardOutput = whichPipe
                    which.standardError = FileHandle.nullDevice
                    try which.run()
                    which.waitUntilExit()
                    guard which.terminationStatus == 0,
                        let resolved = String(
                            data: whichPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        !resolved.isEmpty
                    else {
                        throw AgentSDKError.binaryNotFound
                    }
                    firstToken = resolved
                }
                executablePath = firstToken
                finalArguments = Array(tokens.dropFirst()) + arguments
            } else {
                guard let resolved = binaryPathOverride ?? BinaryLocator.locate() else {
                    throw AgentSDKError.binaryNotFound
                }
                executablePath = resolved
                finalArguments = arguments
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = finalArguments
            proc.currentDirectoryURL = workingDirectory

            var env = ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            for (k, v) in envOverrides { env[k] = v }
            proc.environment = env

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = stderr

            let fullCommand = ([executablePath] + proc.arguments!).map { arg in
                arg.contains(" ") ? "\"\(arg)\"" : arg
            }.joined(separator: " ")
            NSLog("[AgentSDK] Launch: %@", fullCommand)

            do {
                try proc.run()
            } catch {
                throw AgentSDKError.launchFailed(underlying: error)
            }

            return (proc, stdin, stdout, stderr)
        }.value

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        proc.terminationHandler = { [weak self] process in
            self?.drainStderr()
            self?.onProcessExit?(process.terminationStatus)
        }

        readStdoutAsync()
    }

    /// Stops the CLI subprocess immediately.
    public func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        cleanup()
    }

    /// Gracefully shuts down the CLI subprocess.
    ///
    /// Closes stdin (sends EOF) and waits up to 5 seconds for the process to exit
    /// on its own so it can finish writing the session file. On timeout, force-terminates.
    /// `completion` is invoked on the main thread.
    public func close(completion: (() -> Void)? = nil) {
        guard let proc = process, proc.isRunning else {
            cleanup()
            completion?()
            return
        }

        // Close stdin so the CLI exits on EOF.
        stdinQueue.async { [weak self] in
            self?.stdinPipe?.fileHandleForWriting.closeFile()
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(5)
            while proc.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if proc.isRunning {
                NSLog("[AgentSDK] Graceful shutdown timed out, terminating")
                proc.terminate()
            }

            DispatchQueue.main.async {
                self?.cleanup()
                completion?()
            }
        }
    }

    // MARK: - Send User Message

    public func sendMessage(_ text: String, extra: [String: Any] = [:]) {
        sendUserJSON(content: text, extra: extra)
    }

    /// Sends a user message with an array `content` (mixed text / image blocks).
    /// Each block is a raw dict, e.g. `["type": "image", "source": ["type": "base64", ...]]`.
    public func sendMessage(contentBlocks: [[String: Any]], extra: [String: Any] = [:]) {
        sendUserJSON(content: contentBlocks, extra: extra)
    }

    private func sendUserJSON(content: Any, extra: [String: Any]) {
        var json: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        if let sessionId = lastKnownSessionId {
            json["session_id"] = sessionId
        }
        for (k, v) in extra {
            json[k] = v
        }
        writeJSON(json)
    }

    // MARK: - Control Requests

    public func interrupt(completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(subtype: "interrupt", completion: completion)
    }

    public func setModel(_ model: String, completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(subtype: "set_model", params: ["model": model], completion: completion)
    }

    public func setMaxThinkingTokens(_ tokens: Int, completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(
            subtype: "set_max_thinking_tokens", params: ["max_thinking_tokens": tokens], completion: completion)
    }

    public func setPermissionMode(_ mode: PermissionMode, completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(subtype: "set_permission_mode", params: ["mode": mode.rawValue], completion: completion)
    }

    /// Rewinds files back to the state at the given user message.
    public func rewindFiles(
        toMessageId messageId: String, dryRun: Bool = false, completion: (([String: Any]) -> Void)? = nil
    ) {
        sendControlRequest(
            subtype: "rewind_files", params: ["user_message_id": messageId, "dry_run": dryRun], completion: completion)
    }

    public func stopTask(taskId: String, completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(subtype: "stop_task", params: ["task_id": taskId], completion: completion)
    }

    /// Applies flag settings (merged into the runtime flag settings layer).
    ///
    /// ```swift
    /// var settings = FlagSettings()
    /// settings.effortLevel = .set(.high)
    /// settings.fastMode = .set(true)
    /// session.applyFlagSettings(settings) { response in
    ///     print(response.isSuccess)
    /// }
    /// ```
    public func applyFlagSettings(_ settings: FlagSettings, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        let dict = settings.toDictionary()
        let keys = dict.keys.sorted().joined(separator: ", ")
        NSLog("[AgentSDK] applyFlagSettings: {%@}", keys)
        sendControlRequest(subtype: "apply_flag_settings", params: ["settings": dict]) { response in
            let result = FlagSettingsResponse(response)
            if result.isSuccess {
                NSLog("[AgentSDK] applyFlagSettings succeeded")
            } else {
                NSLog("[AgentSDK] applyFlagSettings failed: %@", result.errorMessage ?? "unknown")
            }
            completion?(result)
        }
    }

    public func applyFlagSettings(_ settings: FlagSettings) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            applyFlagSettings(settings) { response in
                continuation.resume(returning: response)
            }
        }
    }

    // MARK: - Flag Settings Convenience

    public func setEffort(_ effort: Effort, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.effortLevel = .set(effort)
        applyFlagSettings(s, completion: completion)
    }

    /// Clears the effort override (reverts to the default).
    public func clearEffort(completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.effortLevel = .clear
        applyFlagSettings(s, completion: completion)
    }

    public func setFastMode(_ enabled: Bool, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.fastMode = .set(enabled)
        applyFlagSettings(s, completion: completion)
    }

    public func setThinkingEnabled(_ enabled: Bool, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.alwaysThinkingEnabled = .set(enabled)
        applyFlagSettings(s, completion: completion)
    }

    public func setLanguage(_ language: String, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.language = .set(language)
        applyFlagSettings(s, completion: completion)
    }

    public func setOutputStyle(_ style: String, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.outputStyle = .set(style)
        applyFlagSettings(s, completion: completion)
    }

    /// Sets the model via flag settings (goes through the settings cascade and also triggers a model override).
    public func setModelViaSettings(_ model: String, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.model = .set(model)
        applyFlagSettings(s, completion: completion)
    }

    public func setAutoMemory(_ enabled: Bool, completion: ((FlagSettingsResponse) -> Void)? = nil) {
        var s = FlagSettings()
        s.autoMemoryEnabled = .set(enabled)
        applyFlagSettings(s, completion: completion)
    }

    // MARK: - Flag Settings Convenience (async)

    public func setEffort(_ effort: Effort) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            setEffort(effort) { continuation.resume(returning: $0) }
        }
    }

    public func clearEffort() async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            clearEffort { continuation.resume(returning: $0) }
        }
    }

    public func setFastMode(_ enabled: Bool) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            setFastMode(enabled) { continuation.resume(returning: $0) }
        }
    }

    public func setThinkingEnabled(_ enabled: Bool) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            setThinkingEnabled(enabled) { continuation.resume(returning: $0) }
        }
    }

    public func setLanguage(_ language: String) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            setLanguage(language) { continuation.resume(returning: $0) }
        }
    }

    public func setOutputStyle(_ style: String) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            setOutputStyle(style) { continuation.resume(returning: $0) }
        }
    }

    public func setModelViaSettings(_ model: String) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            setModelViaSettings(model) { continuation.resume(returning: $0) }
        }
    }

    public func setAutoMemory(_ enabled: Bool) async -> FlagSettingsResponse {
        await withCheckedContinuation { continuation in
            setAutoMemory(enabled) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - MCP Control

    public func mcpReconnect(serverName: String, completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(subtype: "mcp_reconnect", params: ["serverName": serverName], completion: completion)
    }

    public func mcpToggle(serverName: String, enabled: Bool, completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(
            subtype: "mcp_toggle", params: ["serverName": serverName, "enabled": enabled], completion: completion)
    }

    public func mcpStatus(completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(subtype: "mcp_status", completion: completion)
    }

    public func mcpSetServers(_ servers: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        sendControlRequest(subtype: "mcp_set_servers", params: servers, completion: completion)
    }

    // MARK: - Initialize Control Request

    /// Sends the `initialize` control request (configures systemPrompt, hooks, MCP servers, ...).
    /// Must be called after `start()` and before `sendMessage()`.
    public func initialize(
        systemPrompt: String? = nil,
        appendSystemPrompt: String? = nil,
        hooks: [String: Any]? = nil,
        mcpServers: [String]? = nil,
        promptSuggestions: Bool? = nil,
        completion: ((InitializeResponse?) -> Void)? = nil
    ) {
        var params: [String: Any] = [:]
        if let systemPrompt { params["systemPrompt"] = systemPrompt }
        if let appendSystemPrompt { params["appendSystemPrompt"] = appendSystemPrompt }
        if let hooks { params["hooks"] = hooks }
        if let mcpServers { params["sdkMcpServers"] = mcpServers }
        if let promptSuggestions { params["promptSuggestions"] = promptSuggestions }
        sendControlRequest(subtype: "initialize", params: params) { response in
            let inner = response["response"] as? [String: Any]
            let parsed = inner.flatMap { try? InitializeResponse(json: $0) }
            completion?(parsed)
        }
    }

    // MARK: - Generic Control Request

    /// Sends an arbitrary control request.
    public func sendControlRequest(
        subtype: String,
        params: [String: Any] = [:],
        completion: (([String: Any]) -> Void)? = nil
    ) {
        let requestId = UUID().uuidString
        var request: [String: Any] = ["subtype": subtype]
        for (k, v) in params { request[k] = v }
        if let completion {
            pendingControlResponses[requestId] = completion
        }
        writeJSON([
            "type": "control_request",
            "request_id": requestId,
            "request": request,
        ])
    }

    // MARK: - Private: Process Arguments

    private func buildArguments() -> [String] {
        let config = configuration
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

    // MARK: - Private: Stdout Reading

    private func readStdoutAsync() {
        guard let pipe = stdoutPipe else { return }
        let handle = pipe.fileHandleForReading

        readQueue.async { [weak self] in
            var buffer = Data()
            let newline = UInt8(ascii: "\n")

            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)

                while let idx = buffer.firstIndex(of: newline) {
                    let lineData = buffer[buffer.startIndex..<idx]
                    buffer.removeSubrange(buffer.startIndex...idx)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        self?.routeLine(line)
                    }
                }
            }

            if !buffer.isEmpty,
                let line = String(data: buffer, encoding: .utf8)?
                    .trimmingCharacters(in: .newlines),
                !line.isEmpty
            {
                self?.routeLine(line)
            }
        }
    }

    // MARK: - Private: Line Routing

    private func routeLine(_ line: String) {
        guard let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return
        }

        // Track session ID from messages
        if let sid = json["sessionId"] as? String ?? json["session_id"] as? String {
            lastKnownSessionId = sid
        }

        if configuration.messageExportDirectory != nil {
            exportLine(line)
        }

        switch type {
        case "control_request":
            handleControlRequest(json)

        case "control_cancel_request":
            if let requestId = json["request_id"] as? String {
                pendingPermissions.removeValue(forKey: requestId)
                onPermissionCancelled?(requestId)
            }

        case "control_response":
            if let response = json["response"] as? [String: Any],
                let requestId = response["request_id"] as? String
            {
                pendingControlResponses.removeValue(forKey: requestId)?(response)
            }

        case "keep_alive":
            break

        default:
            if let message = try? resolver.resolve(json) {
                onMessage?(message)
            }
        }
    }

    // MARK: - Private: Control Request Handling

    private func handleControlRequest(_ json: [String: Any]) {
        guard let requestId = json["request_id"] as? String,
            let request = json["request"] as? [String: Any],
            let subtype = request["subtype"] as? String
        else {
            return
        }

        // Merge request_id from envelope into request dict for struct init
        var merged = request
        merged["request_id"] = requestId

        switch subtype {
        case "can_use_tool":
            guard let permReq = try? PermissionRequest(json: merged) else { return }
            pendingPermissions[requestId] = permReq
            if let handler = onPermissionRequest {
                handler(permReq) { [weak self] decision in
                    guard let self else { return }
                    self.pendingPermissions.removeValue(forKey: requestId)
                    self.writeJSON(self.buildPermissionResponse(request: permReq, decision: decision))
                }
            } else {
                pendingPermissions.removeValue(forKey: requestId)
                writeJSON(buildPermissionResponse(request: permReq, decision: .deny(reason: "No permission handler")))
            }

        case "hook_callback":
            guard let hookReq = try? HookRequest(json: merged) else { return }
            let result = onHookRequest?(hookReq) ?? .success()
            writeJSON(buildHookResponse(requestId: requestId, result: result))

        case "mcp_message":
            guard let mcpReq = try? MCPRequest(json: merged) else { return }
            let result = onMCPRequest?(mcpReq) ?? .success()
            writeJSON(buildMCPResponse(requestId: requestId, result: result))

        case "elicitation":
            guard let elReq = try? ElicitationRequest(json: merged) else { return }
            let result = onElicitationRequest?(elReq) ?? .cancel
            writeJSON(buildElicitationResponse(requestId: requestId, result: result))

        default:
            writeJSON(buildErrorResponse(requestId: requestId, error: "Unsupported: \(subtype)"))
        }
    }

    // MARK: - Private: Response Building

    private func buildPermissionResponse(request: PermissionRequest, decision: PermissionDecision) -> [String: Any] {
        let responseBody: [String: Any]

        switch decision {
        case .allow(let updatedInput):
            var body: [String: Any] = [
                "behavior": "allow",
                "updatedInput": updatedInput ?? request.rawInput,
            ]
            if let toolUseId = request.toolUseId { body["toolUseID"] = toolUseId }
            responseBody = body

        case .allowAlways(let updatedInput, let updatedPermissions):
            var body: [String: Any] = [
                "behavior": "allow",
                "updatedInput": updatedInput ?? request.rawInput,
                "updatedPermissions": updatedPermissions ?? request.permissionSuggestions?.map {
                    $0.toJSON() as! [String: Any]
                } ?? [],
            ]
            if let toolUseId = request.toolUseId { body["toolUseID"] = toolUseId }
            responseBody = body

        case .deny(let reason, let interrupt):
            var body: [String: Any] = [
                "behavior": "deny",
                "message": reason.isEmpty ? "User rejected \(request.toolName)" : reason,
            ]
            if interrupt { body["interrupt"] = true }
            if let toolUseId = request.toolUseId { body["toolUseID"] = toolUseId }
            responseBody = body
        }

        return [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": request.requestId,
                "response": responseBody,
            ],
        ]
    }

    private func buildHookResponse(requestId: String, result: HookResult) -> [String: Any] {
        switch result {
        case .success(let output):
            return [
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": requestId,
                    "response": output ?? [:],
                ] as [String: Any],
            ]
        case .error(let message):
            return [
                "type": "control_response",
                "response": [
                    "subtype": "error",
                    "request_id": requestId,
                    "error": message,
                ],
            ]
        }
    }

    private func buildMCPResponse(requestId: String, result: MCPResponse) -> [String: Any] {
        switch result {
        case .success(let response):
            return [
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": requestId,
                    "response": response ?? [:],
                ] as [String: Any],
            ]
        case .error(let message):
            return [
                "type": "control_response",
                "response": [
                    "subtype": "error",
                    "request_id": requestId,
                    "error": message,
                ],
            ]
        }
    }

    private func buildElicitationResponse(requestId: String, result: ElicitationResult) -> [String: Any] {
        let resp: [String: Any]
        switch result {
        case .respond(let data):
            resp = ["action": "respond", "data": data]
        case .cancel:
            resp = ["action": "cancel"]
        }
        return [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestId,
                "response": resp,
            ],
        ]
    }

    private func buildErrorResponse(requestId: String, error: String) -> [String: Any] {
        [
            "type": "control_response",
            "response": [
                "subtype": "error",
                "request_id": requestId,
                "error": error,
            ],
        ]
    }

    // MARK: - Private: Stdin Writing

    private func writeJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
            var line = String(data: data, encoding: .utf8)
        else { return }
        if configuration.messageExportDirectory != nil {
            exportLine(line)
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }
        stdinQueue.async { [weak self] in
            self?.stdinPipe?.fileHandleForWriting.write(lineData)
        }
    }

    // MARK: - Private: Stderr

    private func drainStderr() {
        guard let pipe = stderrPipe else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return }
        onStderr?(text)
    }

    // MARK: - Private: Message Export

    private func exportLine(_ line: String) {
        guard let dir = configuration.messageExportDirectory else { return }

        let sessionId = lastKnownSessionId ?? "unknown"

        // Open a new file handle when the session ID changes or none is open yet.
        if exportFileHandle == nil || exportSessionId != sessionId {
            exportFileHandle?.closeFile()
            exportFileHandle = nil
            exportSessionId = sessionId

            let fileURL = dir.appendingPathComponent("\(sessionId).jsonl")
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            exportFileHandle = FileHandle(forWritingAtPath: fileURL.path)
            exportFileHandle?.seekToEndOfFile()
        }

        if let data = (line + "\n").data(using: .utf8) {
            exportFileHandle?.write(data)
            exportFileHandle?.synchronizeFile()
        }
    }

    // MARK: - Private: Cleanup

    private func cleanup() {
        exportFileHandle?.closeFile()
        exportFileHandle = nil
        exportSessionId = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        pendingPermissions.removeAll()
        pendingControlResponses.removeAll()
    }
}

import Foundation
import os

/// A live conversation with the Claude Code CLI over its stream-json protocol.
///
/// ```swift
/// let session = Session(configuration: SessionConfiguration(workingDirectory: projectURL))
/// Task {
///     for await event in session.events {
///         switch event {
///         case .message(.assistant(let message)): render(message)
///         case .permissionRequest(let request): request.respond(.allow())
///         default: break
///         }
///     }
/// }
/// try await session.start()
/// try session.send(UserInput("Summarize README.md"))
/// ```
///
/// Everything the CLI reports arrives on ``events``, in order, from a single
/// stream; commands are plain method calls. Requests that wait for the CLI's
/// answer are `async throws`: cancelling the calling task withdraws the
/// request, and a process exit fails it with ``AgentSDKError/processExited(_:)``.
/// All methods are safe to call from any thread.
public final class Session: @unchecked Sendable {
    /// Everything the session reports, in order. Iterate it once; it
    /// finishes after ``SessionEvent/exited(_:)``.
    public let events: AsyncStream<SessionEvent>

    private let configuration: SessionConfiguration
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let exporter: MessageExporter?

    private struct State {
        var phase = Phase.idle
        var process: CLIProcess?
        var sessionID: String?
        var nextRequestID = 0
        var pendingControls: [String: PendingControl] = [:]
        var permissions: [String: PermissionRequest] = [:]
        var exitWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum Phase {
        case idle, running
        case exited(Termination)
    }

    private struct PendingControl {
        let subtype: String
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    public init(configuration: SessionConfiguration) {
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        exporter = configuration.messageExportDirectory.map(MessageExporter.init)
        state.withLock {
            $0.sessionID = configuration.sessionId ?? configuration.resume.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    deinit {
        state.withLock { $0.process }?.terminate()
        continuation.finish()
    }

    /// The CLI's session id, once known. Changes when the CLI forks or
    /// clears the conversation.
    var sessionID: String? { state.withLock { $0.sessionID } }

    /// `true` between a successful ``start()`` and the process exiting.
    public var isRunning: Bool {
        state.withLock { if case .running = $0.phase { return true } else { return false } }
    }

    // MARK: - Lifecycle

    /// Launches the CLI and performs the protocol handshake.
    @discardableResult
    public func start() async throws -> InitializationResult {
        try state.withLock { s in
            guard case .idle = s.phase else { throw AgentSDKError.alreadyStarted }
            s.phase = .running
        }
        let process: CLIProcess
        do {
            process = try await Task.detached { [configuration] in CLIProcess(launch: try configuration.launch()) }
                .value
        } catch {
            finish(Termination(exitCode: -1, stderr: error.localizedDescription))
            throw error
        }
        state.withLock { $0.process = process }
        do {
            try process.run(
                onLine: { [weak self] line in self?.receive(line) },
                onExit: { [weak self] termination in self?.finish(termination) })
        } catch {
            finish(Termination(exitCode: -1, stderr: error.localizedDescription))
            throw error
        }

        var params: [String: JSONValue] = [:]
        if configuration.promptSuggestions { params["promptSuggestions"] = true }
        do {
            let response = try await sendControlRequest("initialize", params)
            guard let result = try? response.decode(InitializationResult.self) else {
                throw AgentSDKError.invalidResponse(subtype: "initialize")
            }
            return result
        } catch {
            process.terminate()
            throw error
        }
    }

    /// Asks the CLI to finish its current turn and exit, then waits for it.
    /// Terminates the process if it has not exited after `timeout` seconds.
    public func close(timeout: TimeInterval = 5) async {
        guard let process = state.withLock({ $0.process }) else { return }
        process.closeStdin()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            process.terminate()
        }
        await waitForExit()
        watchdog.cancel()
    }

    /// Terminates the CLI process immediately.
    public func terminate() {
        state.withLock { $0.process }?.terminate()
    }

    // MARK: - Commands

    /// Sends a prompt. While a turn runs, the CLI queues or folds it according
    /// to ``UserInput/priority``; follow it through ``CommandLifecycle``.
    public func send(_ input: UserInput) throws {
        var line = input.jsonValue
        if case .object(var o) = line {
            o["session_id"] = .string(sessionID ?? "")
            line = .object(o)
        }
        try write(line)
    }

    /// Interrupts the running turn. Queued prompts survive.
    public func interrupt() async throws {
        _ = try await sendControlRequest("interrupt")
    }

    /// Switches the model; `nil` restores the default.
    func setModel(_ model: String?) async throws {
        _ = try await sendControlRequest("set_model", ["model": model.map(JSONValue.string) ?? .null])
    }

    func setPermissionMode(_ mode: PermissionMode) async throws {
        _ = try await sendControlRequest("set_permission_mode", ["mode": .string(mode.rawValue)])
    }

    /// Caps thinking tokens; `nil` removes the cap.
    func setMaxThinkingTokens(_ tokens: Int?) async throws {
        _ = try await sendControlRequest(
            "set_max_thinking_tokens", ["max_thinking_tokens": tokens.map { .number(Double($0)) } ?? .null])
    }

    /// Changes the session's flag settings layer, which sits above user,
    /// project and local settings and below managed policy. The layer is the
    /// launch settings (``SessionConfiguration/settings``) with the runtime
    /// values from every call to this method on top.
    ///
    /// The merge is by top-level key: each key in `settings` replaces its
    /// whole runtime value (objects such as ``SettingsKey/permissions`` are
    /// not merged field by field), a key recorded with ``Settings/unset(_:)``
    /// loses its runtime value and falls back to its launch value (except the
    /// four that reset session state; see ``Settings``), and keys not
    /// mentioned are kept. Most settings apply from the next request;
    /// `model`, `agent` and `fastMode` wait for the running turn to end, and
    /// this call returns once they are applied.
    ///
    /// The CLI accepts the request even when a value breaks its schema, and
    /// then ignores every runtime value until the bad one is replaced or
    /// unset; ``settings()`` reports it in ``SettingsSnapshot/errors``.
    public func applySettings(_ settings: Settings) async throws {
        _ = try await sendControlRequest("apply_flag_settings", ["settings": .object(settings.json)])
    }

    /// The settings as the session sees them: every layer, their merge, and
    /// the values the session resolved.
    public func settings() async throws -> SettingsSnapshot {
        SettingsSnapshot(response: try await sendControlRequest("get_settings"))
    }

    /// How the context window is currently spent.
    public func contextUsage() async throws -> ContextUsage {
        let response = try await sendControlRequest("get_context_usage")
        guard let usage = try? response.decode(ContextUsage.self) else {
            throw AgentSDKError.invalidResponse(subtype: "get_context_usage")
        }
        return usage
    }

    /// Asks a one-off question about the conversation (`/btw`). The answer
    /// comes from a separate tool-less model call; it is not added to the
    /// transcript and does not disturb the running turn. `nil` when the model
    /// produced no text.
    public func askSideQuestion(_ question: String) async throws -> SideQuestionAnswer? {
        let response = try await sendControlRequest("side_question", ["question": .string(question)])
        guard let text = response["response"]?.stringValue else { return nil }
        return SideQuestionAnswer(response: text, synthetic: response["synthetic"]?.boolValue ?? false)
    }

    /// Takes the conversation back to before the prompt whose uuid is
    /// `messageUUID` (``UserInput/uuid``), as editing that prompt does. The
    /// CLI refuses while the turn it just reported is still winding down;
    /// ``RewindResult/reason`` says so.
    public func rewindConversation(to messageUUID: String) async throws -> RewindResult {
        let response = try await sendControlRequest(
            "rewind_conversation", ["target_message_uuid": .string(messageUUID)])
        return RewindResult(
            rewound: response["rewound"]?.boolValue ?? false, reason: response["reason"]?.stringValue)
    }

    /// Stops a background task (see ``SystemMessage/taskStarted(_:)``).
    func stopTask(id: String) async throws {
        _ = try await sendControlRequest("stop_task", ["task_id": .string(id)])
    }

    /// Sends a control request and returns the CLI's response payload
    /// (`.null` when it has none). The typed methods above are built on it.
    func sendControlRequest(_ subtype: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let id = state.withLock { s -> String in
            s.nextRequestID += 1
            return "req_\(s.nextRequestID)"
        }
        var request = params
        request["subtype"] = .string(subtype)
        let line: JSONValue = ["type": "control_request", "request_id": .string(id), "request": .object(request)]

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let failure = state.withLock { s -> Error? in
                    switch s.phase {
                    case .idle: return AgentSDKError.notRunning
                    case .exited(let termination): return AgentSDKError.processExited(termination)
                    case .running:
                        if Task.isCancelled { return CancellationError() }
                        s.pendingControls[id] = PendingControl(subtype: subtype, continuation: continuation)
                        return nil
                    }
                }
                if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    try? write(line)
                }
            }
        } onCancel: {
            guard let pending = state.withLock({ $0.pendingControls.removeValue(forKey: id) }) else { return }
            pending.continuation.resume(throwing: CancellationError())
            try? write(["type": "control_cancel_request", "request_id": .string(id)])
        }
    }

    // MARK: - Output

    private func receive(_ data: Data) {
        exporter?.append(data, sessionID: sessionID)
        guard let line = try? JSONDecoder().decode(OutputLine.self, from: data) else { return }
        switch line {
        case .message(let message, let sessionID):
            if let sessionID { state.withLock { $0.sessionID = sessionID } }
            continuation.yield(.message(message))
        case .controlResponse(let response):
            settle(response)
        case .controlRequest(let id, let request):
            answer(request, id: id)
        case .controlCancel(let id):
            if let request = state.withLock({ $0.permissions.removeValue(forKey: id) }) {
                request.invalidate()
                continuation.yield(.permissionRequestCancelled(id: id))
            }
        case .ignored:
            break
        }
    }

    /// Resolves one of our pending requests. Responses to ids we did not
    /// issue (the CLI echoes our own answers back) are ignored.
    private func settle(_ response: JSONValue) {
        guard let id = response["request_id"]?.stringValue,
            let pending = state.withLock({ $0.pendingControls.removeValue(forKey: id) })
        else { return }
        if response["subtype"]?.stringValue == "error" {
            let message = response["error"]?.stringValue ?? "unknown error"
            pending.continuation.resume(
                throwing: AgentSDKError.controlRequestFailed(subtype: pending.subtype, message: message))
        } else {
            pending.continuation.resume(returning: response["response"] ?? .null)
        }
    }

    /// Answers a request from the CLI. Tool permissions go to the consumer;
    /// everything else gets the protocol's neutral answer.
    private func answer(_ request: JSONValue, id: String) {
        switch request["subtype"]?.stringValue {
        case "can_use_tool":
            guard let permission = makePermissionRequest(request, id: id) else {
                reply(id, error: "Malformed can_use_tool request")
                return
            }
            state.withLock { $0.permissions[id] = permission }
            continuation.yield(.permissionRequest(permission))
        case "hook_callback":
            reply(id, success: .object([:]))
        case "elicitation":
            reply(id, success: ["action": "cancel"])
        case let subtype:
            reply(id, error: "Unsupported control request subtype: \(subtype ?? "")")
        }
    }

    private func makePermissionRequest(_ request: JSONValue, id: String) -> PermissionRequest? {
        guard let toolName = request["tool_name"]?.stringValue else { return nil }
        let toolUseID = request["tool_use_id"]?.stringValue ?? ""
        let suggestions = (request["permission_suggestions"]?.arrayValue ?? []).compactMap {
            try? $0.decode(PermissionUpdate.self)
        }
        return PermissionRequest(
            id: id, toolName: toolName, toolUseID: toolUseID, input: request["input"] ?? .object([:]),
            suggestions: suggestions, decisionReason: request["decision_reason"]?.stringValue,
            decisionReasonType: request["decision_reason_type"]?.stringValue,
            blockedPath: request["blocked_path"]?.stringValue, agentID: request["agent_id"]?.stringValue,
            onRespond: { [weak self] decision in
                guard let self, self.state.withLock({ $0.permissions.removeValue(forKey: id) }) != nil else { return }
                self.reply(id, success: Self.permissionResponse(decision, toolUseID: toolUseID))
            })
    }

    private static func permissionResponse(_ decision: PermissionDecision, toolUseID: String) -> JSONValue {
        var body: [String: JSONValue] = ["toolUseID": .string(toolUseID)]
        switch decision {
        case .allow(let updatedInput, let updatedPermissions):
            body["behavior"] = "allow"
            if let updatedInput { body["updatedInput"] = updatedInput }
            if !updatedPermissions.isEmpty { body["updatedPermissions"] = .array(updatedPermissions.map(\.jsonValue)) }
        case .deny(let message, let interrupt):
            body["behavior"] = "deny"
            body["message"] = .string(message)
            if interrupt { body["interrupt"] = true }
        }
        return .object(body)
    }

    private func reply(_ id: String, success payload: JSONValue) {
        try? write([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(id), "response": payload],
        ])
    }

    private func reply(_ id: String, error message: String) {
        try? write([
            "type": "control_response",
            "response": ["subtype": "error", "request_id": .string(id), "error": .string(message)],
        ])
    }

    // MARK: - Plumbing

    private func write(_ line: JSONValue) throws {
        guard
            let process = state.withLock({ s -> CLIProcess? in
                if case .running = s.phase { return s.process }
                return nil
            })
        else { throw AgentSDKError.notRunning }
        let data = try JSONEncoder().encode(line)
        exporter?.append(data, sessionID: sessionID)
        process.writeLine(data)
    }

    private func finish(_ termination: Termination) {
        let (controls, permissions, waiters) = state.withLock { s in
            s.phase = .exited(termination)
            defer {
                s.pendingControls = [:]
                s.permissions = [:]
                s.exitWaiters = []
            }
            return (Array(s.pendingControls.values), Array(s.permissions.values), s.exitWaiters)
        }
        for pending in controls {
            pending.continuation.resume(throwing: AgentSDKError.processExited(termination))
        }
        for request in permissions {
            request.invalidate()
            continuation.yield(.permissionRequestCancelled(id: request.id))
        }
        exporter?.close()
        continuation.yield(.exited(termination))
        continuation.finish()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForExit() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let exited = state.withLock { s -> Bool in
                if case .exited = s.phase { return true }
                s.exitWaiters.append(waiter)
                return false
            }
            if exited { waiter.resume() }
        }
    }
}

/// One stdout line, routed: protocol plumbing is handled by the session,
/// everything else is a ``Message``. Decoded in a single pass.
private enum OutputLine: Decodable {
    case message(Message, sessionID: String?)
    case controlRequest(id: String, request: JSONValue)
    case controlResponse(JSONValue)
    case controlCancel(id: String)
    case ignored

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        switch c.lenient(String.self, "type") {
        case "control_request":
            guard let id = c.lenient(String.self, "request_id"), let request = c.lenient(JSONValue.self, "request")
            else {
                self = .ignored
                return
            }
            self = .controlRequest(id: id, request: request)
        case "control_response":
            self = c.lenient(JSONValue.self, "response").map(OutputLine.controlResponse) ?? .ignored
        case "control_cancel_request":
            self = c.lenient(String.self, "request_id").map(OutputLine.controlCancel) ?? .ignored
        case "keep_alive":
            self = .ignored
        default:
            self = .message(try Message(from: decoder), sessionID: c.lenient(String.self, "session_id"))
        }
    }
}

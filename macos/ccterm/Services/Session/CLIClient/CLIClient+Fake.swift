#if DEBUG

import AgentSDK
import Foundation

/// In-memory `CLIClient` for unit tests. **DEBUG build only.**
///
/// Two responsibilities:
/// - Record every outgoing call from the handle (start / send / interrupt
///   / setModel / ...) so a test can assert "the handle did issue the
///   RPC."
/// - Provide imperative pushers (`pushMessage` / `simulateInitialize` /
///   `simulateProcessExit` / ...) so a test can drive the handle's
///   incoming side without standing up a real CLI subprocess.
///
/// Lifetime is tied to the test; nothing escapes the process.
final class FakeCLIClient: CLIClient {

    // MARK: - Recorded outgoing calls

    struct SendCall {
        let text: String?
        let blocks: [[String: Any]]?
        let extra: [String: Any]
    }

    private(set) var startCalls: Int = 0
    private(set) var closeCalls: Int = 0
    private(set) var sendCalls: [SendCall] = []
    private(set) var initializeCalls: [(promptSuggestions: Bool, completion: (InitializeResponse?) -> Void)] = []
    private(set) var interruptCalls: [([String: Any]) -> Void] = []
    private(set) var modelCalls: [String] = []
    private(set) var effortCalls: [Effort] = []
    private(set) var permissionModeCalls: [AgentSDK.PermissionMode] = []
    private(set) var fastModeCalls: [Bool] = []
    private(set) var flagSettingsCalls: [FlagSettings] = []

    /// Set to throw from `start()`; default succeeds.
    var startError: Error?

    // MARK: - CLIClient (identity + callbacks)

    var lastKnownSessionId: String?
    var onMessage: ((Message2) -> Void)?
    var onPermissionRequest: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)?
    var onPermissionCancelled: ((String) -> Void)?
    var onProcessExit: ((Int32) -> Void)?
    var onStderr: ((String) -> Void)?
    var onHookRequest: ((HookRequest) -> HookResult)?
    var onMCPRequest: ((MCPRequest) -> MCPResponse)?
    var onElicitationRequest: ((ElicitationRequest) -> ElicitationResult)?

    init() {}

    /// Match the macOS 26 workaround used elsewhere in the codebase —
    /// see `Session.deinit` for the bug rationale.
    nonisolated deinit {}

    // MARK: - Lifecycle

    func start() async throws {
        startCalls += 1
        if let startError {
            throw startError
        }
    }

    func close() {
        closeCalls += 1
    }

    // MARK: - Control requests

    func initialize(
        promptSuggestions: Bool,
        completion: @escaping (InitializeResponse?) -> Void
    ) {
        initializeCalls.append((promptSuggestions, completion))
    }

    func interrupt(completion: @escaping ([String: Any]) -> Void) {
        interruptCalls.append(completion)
    }

    // MARK: - Messaging

    func sendMessage(_ text: String, extra: [String: Any]) {
        sendCalls.append(SendCall(text: text, blocks: nil, extra: extra))
    }

    func sendMessage(contentBlocks: [[String: Any]], extra: [String: Any]) {
        sendCalls.append(SendCall(text: nil, blocks: contentBlocks, extra: extra))
    }

    // MARK: - Configuration RPCs

    func setModel(_ model: String) {
        modelCalls.append(model)
    }

    func setEffort(_ effort: Effort) {
        effortCalls.append(effort)
    }

    func setPermissionMode(_ mode: AgentSDK.PermissionMode) {
        permissionModeCalls.append(mode)
    }

    func setFastMode(_ enabled: Bool) {
        fastModeCalls.append(enabled)
    }

    func applyFlagSettings(_ settings: FlagSettings) {
        flagSettingsCalls.append(settings)
    }

    // MARK: - Test drivers (push events back to the handle)

    /// Deliver one Message2 through `onMessage` as if the CLI streamed it.
    func pushMessage(_ message: Message2) {
        onMessage?(message)
    }

    /// Drive the most recently queued `initialize(...)` completion. Tests
    /// call this after `bootstrap` has awaited the initialize result.
    func completeInitialize(with response: InitializeResponse?) {
        guard !initializeCalls.isEmpty else { return }
        let call = initializeCalls.removeFirst()
        call.completion(response)
    }

    /// Drive the most recently queued `interrupt(...)` completion.
    func completeInterrupt(response: [String: Any] = [:]) {
        guard !interruptCalls.isEmpty else { return }
        let cb = interruptCalls.removeFirst()
        cb(response)
    }

    /// Fire the process-exit callback.
    func simulateProcessExit(code: Int32) {
        onProcessExit?(code)
    }

    func simulateStderr(_ text: String) {
        onStderr?(text)
    }

    func simulatePermissionRequest(
        _ request: PermissionRequest,
        completion: @escaping (PermissionDecision) -> Void
    ) {
        onPermissionRequest?(request, completion)
    }
}

#endif

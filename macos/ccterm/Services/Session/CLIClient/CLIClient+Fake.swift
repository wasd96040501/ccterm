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
    var onStreamEvent: ((Message2StreamEvent) -> Void)?
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

    func closeAsync() async {
        closeCalls += 1
        closeAsyncCalls += 1
        await closeAsyncHook?()
    }

    /// Optional async hook fired by `closeAsync`. Tests use it to
    /// gate the continuation on an explicit signal so the parallel-
    /// shutdown test can observe overlap rather than serial completion.
    var closeAsyncHook: (@Sendable () async -> Void)?
    private(set) var closeAsyncCalls: Int = 0

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

    struct ContextUsageCall {
        let timeout: TimeInterval
        let completion: (ContextUsageOutcome) -> Void
    }
    private(set) var contextUsageCalls: [ContextUsageCall] = []

    func getContextUsage(
        timeout: TimeInterval,
        completion: @escaping (ContextUsageOutcome) -> Void
    ) {
        contextUsageCalls.append(ContextUsageCall(timeout: timeout, completion: completion))
    }

    /// Drive the most recently queued `getContextUsage(...)` completion.
    func completeContextUsage(_ outcome: ContextUsageOutcome) {
        guard !contextUsageCalls.isEmpty else { return }
        let call = contextUsageCalls.removeFirst()
        call.completion(outcome)
    }

    struct SideQuestionCall {
        let question: String
        let completion: (SideQuestionOutcome) -> Void
    }
    private(set) var sideQuestionCalls: [SideQuestionCall] = []

    func askSideQuestion(
        _ question: String,
        completion: @escaping (SideQuestionOutcome) -> Void
    ) {
        sideQuestionCalls.append(SideQuestionCall(question: question, completion: completion))
    }

    /// Drive the oldest queued `askSideQuestion(...)` completion.
    func completeSideQuestion(_ outcome: SideQuestionOutcome) {
        guard !sideQuestionCalls.isEmpty else { return }
        let call = sideQuestionCalls.removeFirst()
        call.completion(outcome)
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

    /// Deliver one streaming partial through `onStreamEvent`, as the SDK does
    /// when `includePartialMessages` is on.
    func pushStreamEvent(_ event: Message2StreamEvent) {
        onStreamEvent?(event)
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

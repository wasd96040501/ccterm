import AgentSDK
import Foundation

/// Production `CLIClient` — a thin forwarding adapter over
/// `AgentSDK.Session`. No state of its own; every method delegates
/// directly. Tests use `FakeCLIClient` (DEBUG) instead.
final class AgentSDKCLIClient: CLIClient {

    private let session: AgentSDK.Session

    init(configuration: SessionConfiguration) {
        self.session = AgentSDK.Session(configuration: configuration)
    }

    /// Match the macOS 26 workaround used by `Session` /
    /// `InMemorySessionRepository`: a default class deinit on instances
    /// dropped from a `@MainActor` context routes through
    /// `swift_task_deinitOnExecutorImpl` and hits the libmalloc abort.
    /// `nonisolated deinit` skips the executor-hop path.
    nonisolated deinit {}

    // MARK: Identity

    var lastKnownSessionId: String? {
        get { session.lastKnownSessionId }
        set { session.lastKnownSessionId = newValue }
    }

    // MARK: Callbacks (1:1 forward to AgentSDK.Session)

    var onMessage: ((Message2) -> Void)? {
        get { session.onMessage }
        set { session.onMessage = newValue }
    }

    var onStreamEvent: ((Message2StreamEvent) -> Void)? {
        get { session.onStreamEvent }
        set { session.onStreamEvent = newValue }
    }

    var onPermissionRequest: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)?
    {
        get { session.onPermissionRequest }
        set { session.onPermissionRequest = newValue }
    }

    var onPermissionCancelled: ((String) -> Void)? {
        get { session.onPermissionCancelled }
        set { session.onPermissionCancelled = newValue }
    }

    var onProcessExit: ((Int32) -> Void)? {
        get { session.onProcessExit }
        set { session.onProcessExit = newValue }
    }

    var onStderr: ((String) -> Void)? {
        get { session.onStderr }
        set { session.onStderr = newValue }
    }

    var onHookRequest: ((HookRequest) -> HookResult)? {
        get { session.onHookRequest }
        set { session.onHookRequest = newValue }
    }

    var onMCPRequest: ((MCPRequest) -> MCPResponse)? {
        get { session.onMCPRequest }
        set { session.onMCPRequest = newValue }
    }

    var onElicitationRequest: ((ElicitationRequest) -> ElicitationResult)? {
        get { session.onElicitationRequest }
        set { session.onElicitationRequest = newValue }
    }

    // MARK: Lifecycle

    func start() async throws {
        try await session.start()
    }

    func close() {
        session.close()
    }

    func closeAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.close { cont.resume() }
        }
    }

    // MARK: Control requests

    func initialize(
        promptSuggestions: Bool,
        completion: @escaping (InitializeResponse?) -> Void
    ) {
        session.initialize(promptSuggestions: promptSuggestions, completion: completion)
    }

    func interrupt(completion: @escaping ([String: Any]) -> Void) {
        session.interrupt(completion: completion)
    }

    func getContextUsage(
        timeout: TimeInterval,
        completion: @escaping (ContextUsageOutcome) -> Void
    ) {
        session.getContextUsage(timeout: timeout, completion: completion)
    }

    func askSideQuestion(
        _ question: String,
        completion: @escaping (SideQuestionOutcome) -> Void
    ) {
        session.askSideQuestion(question, completion: completion)
    }

    // MARK: Messaging

    func sendMessage(_ text: String, extra: [String: Any]) {
        session.sendMessage(text, extra: extra)
    }

    func sendMessage(contentBlocks: [[String: Any]], extra: [String: Any]) {
        session.sendMessage(contentBlocks: contentBlocks, extra: extra)
    }

    // MARK: Configuration RPCs

    func setModel(_ model: String) {
        session.setModel(model)
    }

    func setEffort(_ effort: Effort) {
        session.setEffort(effort)
    }

    func setPermissionMode(_ mode: AgentSDK.PermissionMode) {
        session.setPermissionMode(mode)
    }

    func setFastMode(_ enabled: Bool) {
        session.setFastMode(enabled)
    }

    func applyFlagSettings(_ settings: FlagSettings) {
        session.applyFlagSettings(settings)
    }
}

extension AgentSDKCLIClient {

    /// Default factory used by `Session` when no injection is
    /// supplied. Production callers do not need to pass anything; tests
    /// override with `{ _ in FakeCLIClient() }`.
    @MainActor static let defaultFactory: CLIClientFactory = { configuration in
        AgentSDKCLIClient(configuration: configuration)
    }
}

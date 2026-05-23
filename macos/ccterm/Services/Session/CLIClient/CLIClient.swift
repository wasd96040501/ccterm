import AgentSDK
import Foundation

/// Thin abstraction over `AgentSDK.Session`. The handle's view of the CLI
/// is exactly the methods it actually calls — nothing more. Production
/// uses `AgentSDKCLIClient`; tests inject `FakeCLIClient` (DEBUG-only).
///
/// **Design**: closure-property callbacks mirror `AgentSDK.Session` 1:1
/// so the production wrapper is the boring forwarding adapter. Async
/// methods stay async; completion-callback methods keep the completion
/// form so we don't have to retrofit every call site.
///
/// **Why a protocol, not a struct/closure bundle**: callers (the
/// handle's `bootstrap` / `attachCallbacks` / `writeUserEntryToCLI`)
/// install callbacks immediately after constructing the client and
/// before `start()`, then write to those callbacks from background
/// threads. A reference type with mutable closure properties matches
/// the existing AgentSDK.Session shape without changing call patterns.
protocol CLIClient: AnyObject {

    /// Pre-set this before `start()` so the AgentSDK export writes the
    /// init message under the right session id. Production reads this
    /// from `lastKnownSessionId` on the underlying SDK session.
    var lastKnownSessionId: String? { get set }

    // MARK: Callbacks (assigned by Session.attachCallbacks)

    var onMessage: ((Message2) -> Void)? { get set }
    var onPermissionRequest: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)?
    { get set }
    var onPermissionCancelled: ((String) -> Void)? { get set }
    var onProcessExit: ((Int32) -> Void)? { get set }
    var onStderr: ((String) -> Void)? { get set }
    var onHookRequest: ((HookRequest) -> HookResult)? { get set }
    var onMCPRequest: ((MCPRequest) -> MCPResponse)? { get set }
    var onElicitationRequest: ((ElicitationRequest) -> ElicitationResult)? { get set }

    // MARK: Lifecycle

    func start() async throws
    func close()

    /// Graceful shutdown that completes only after the subprocess has
    /// actually exited (or after the underlying SDK's per-process
    /// timeout forces SIGTERM). Used by the app-quit path so all CLIs
    /// can be shut down in parallel before `NSApplication` finishes
    /// terminating. The synchronous `close()` remains fire-and-forget
    /// for the usual stop-button path.
    func closeAsync() async

    // MARK: Control requests

    func initialize(
        promptSuggestions: Bool,
        completion: @escaping (InitializeResponse?) -> Void
    )
    func interrupt(completion: @escaping ([String: Any]) -> Void)

    /// Requests a context-window-usage breakdown. Falls through to
    /// `.unsupported` on old CLIs (no response within `timeout` seconds).
    /// Always invokes `completion` exactly once.
    func getContextUsage(
        timeout: TimeInterval,
        completion: @escaping (ContextUsageOutcome) -> Void
    )

    // MARK: Messaging

    func sendMessage(_ text: String, extra: [String: Any])
    func sendMessage(contentBlocks: [[String: Any]], extra: [String: Any])

    // MARK: Configuration RPCs

    func setModel(_ model: String)
    func setEffort(_ effort: Effort)
    func setPermissionMode(_ mode: AgentSDK.PermissionMode)
    func setFastMode(_ enabled: Bool)
    func applyFlagSettings(_ settings: FlagSettings)
}

/// Builds a `CLIClient` from a session configuration. Injected into
/// `Session` so bootstrap can construct the client without
/// hard-wiring the `AgentSDK.Session` type. Production default lives on
/// `AgentSDKCLIClient`; tests pass a closure that returns a
/// `FakeCLIClient`.
typealias CLIClientFactory = @MainActor (SessionConfiguration) -> any CLIClient

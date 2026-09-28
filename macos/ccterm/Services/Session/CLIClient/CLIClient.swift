import AgentSDK
import Foundation

/// The runtime's view of a live CLI: exactly the `AgentSDK.Session` surface
/// it uses, as a protocol so tests can inject `FakeCLIClient`. Production
/// passes `AgentSDK.Session` itself (conformance below).
protocol CLIClient: AnyObject {
    /// Everything the CLI reports, in order; finishes after `.exited`.
    var events: AsyncStream<SessionEvent> { get }

    /// Launches the CLI and completes the handshake.
    @discardableResult
    func start() async throws -> InitializationResult
    /// Asks the CLI to exit and waits for it (terminating after a timeout).
    func close(timeout: TimeInterval) async
    func terminate()

    func send(_ input: UserInput) throws
    func interrupt() async throws
    func setModel(_ model: String?) async throws
    func setPermissionMode(_ mode: AgentSDK.PermissionMode) async throws
    func applyFlagSettings(_ settings: [String: JSONValue]) async throws
    func contextUsage() async throws -> ContextUsage
    func askSideQuestion(_ question: String) async throws -> SideQuestionAnswer?
}

extension AgentSDK.Session: CLIClient {}

/// Builds a `CLIClient` for a launch configuration. Injected so tests can
/// return a `FakeCLIClient`; production uses `liveCLIClientFactory`.
typealias CLIClientFactory = @MainActor (SessionConfiguration) -> any CLIClient

/// The production factory: a real `AgentSDK.Session`.
@MainActor let liveCLIClientFactory: CLIClientFactory = { AgentSDK.Session(configuration: $0) }

#if DEBUG

import AgentSDK
import Foundation

/// In-memory `CLIClient` for unit tests. **DEBUG build only.**
///
/// - Records every call the runtime makes (`sent`, `modelCalls`, …).
/// - Holds the calls that wait for the CLI (`start`, `interrupt`,
///   `contextUsage`, `askSideQuestion`) open until the test completes them,
///   so a test controls when — and whether — the "CLI" answers.
/// - Pushes CLI output into `events` (`push`, `simulateExit`, …).
///
/// Main-actor isolated (via `CLIClient`), like the runtime that drives it.
final class FakeCLIClient: CLIClient {
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    // MARK: Recorded calls

    private(set) var startCalls = 0
    private(set) var closeCalls = 0
    private(set) var terminateCalls = 0
    private(set) var sent: [UserInput] = []
    private(set) var interruptCalls = 0
    private(set) var modelCalls: [String?] = []
    private(set) var permissionModeCalls: [AgentSDK.PermissionMode] = []
    private(set) var flagSettingsCalls: [[String: JSONValue]] = []
    private(set) var contextUsageCalls = 0
    private(set) var sideQuestions: [String] = []

    /// Thrown from `start()` instead of waiting for `completeStart`.
    var startError: Error?
    /// Awaited inside `close(timeout:)`; lets a test hold a close open.
    var closeHook: (@Sendable () async -> Void)?

    // MARK: Calls held open

    private var pendingStart: CheckedContinuation<InitializationResult, Error>?
    private var pendingInterrupts: [Held<Void>] = []
    private var pendingContextUsage: [Held<ContextUsage>] = []
    private var pendingSideQuestions: [Held<SideQuestionAnswer?>] = []

    private struct Held<T> {
        let id: UUID
        let continuation: CheckedContinuation<T, Error>
    }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    /// See `Session.deinit` for the macOS 26 executor-hop workaround.
    nonisolated deinit {}

    // MARK: CLIClient

    func start() async throws -> InitializationResult {
        startCalls += 1
        if let startError { throw startError }
        return try await withCheckedThrowingContinuation { pendingStart = $0 }
    }

    func close(timeout: TimeInterval) async {
        closeCalls += 1
        await closeHook?()
    }

    func terminate() {
        terminateCalls += 1
    }

    func send(_ input: UserInput) throws {
        sent.append(input)
    }

    func interrupt() async throws {
        interruptCalls += 1
        try await hold(\.pendingInterrupts)
    }

    func setModel(_ model: String?) async throws {
        modelCalls.append(model)
    }

    func setPermissionMode(_ mode: AgentSDK.PermissionMode) async throws {
        permissionModeCalls.append(mode)
    }

    func applyFlagSettings(_ settings: [String: JSONValue]) async throws {
        flagSettingsCalls.append(settings)
    }

    func contextUsage() async throws -> ContextUsage {
        contextUsageCalls += 1
        return try await hold(\.pendingContextUsage)
    }

    func askSideQuestion(_ question: String) async throws -> SideQuestionAnswer? {
        sideQuestions.append(question)
        return try await hold(\.pendingSideQuestions)
    }

    /// Parks a call until a driver completes it. Cancelling the caller's
    /// task throws `CancellationError`, as `AgentSDK.Session` does.
    private func hold<T>(_ queue: ReferenceWritableKeyPath<FakeCLIClient, [Held<T>]>) async throws -> T {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { self[keyPath: queue].append(Held(id: id, continuation: $0)) }
        } onCancel: {
            Task { @MainActor in
                guard let index = self[keyPath: queue].firstIndex(where: { $0.id == id }) else { return }
                self[keyPath: queue].remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: Test drivers

    /// Whether `start()` is waiting for `completeStart`.
    var isAwaitingStart: Bool { pendingStart != nil }

    /// Finishes the handshake with an `initialize` response object in the
    /// CLI's JSON shape; `[:]` is an empty but valid one.
    func completeStart(with response: JSONValue = [:]) {
        // Every field decodes leniently, so any object is a valid response.
        let result = try! response.decode(InitializationResult.self)
        pendingStart?.resume(returning: result)
        pendingStart = nil
    }

    /// Fails the handshake, as a CLI that dies during startup does.
    func failStart(_ error: Error) {
        pendingStart?.resume(throwing: error)
        pendingStart = nil
    }

    /// Acknowledges the oldest pending `interrupt()`.
    func completeInterrupt() {
        guard !pendingInterrupts.isEmpty else { return }
        pendingInterrupts.removeFirst().continuation.resume()
    }

    /// Answers the oldest pending `contextUsage()`; an error fails it.
    func completeContextUsage(_ result: Result<ContextUsage, Error>) {
        guard !pendingContextUsage.isEmpty else { return }
        pendingContextUsage.removeFirst().continuation.resume(with: result)
    }

    /// Answers the oldest pending `askSideQuestion(_:)`; an error fails it.
    func completeSideQuestion(_ result: Result<SideQuestionAnswer?, Error>) {
        guard !pendingSideQuestions.isEmpty else { return }
        pendingSideQuestions.removeFirst().continuation.resume(with: result)
    }

    /// Delivers one CLI message.
    func push(_ message: Message) {
        continuation.yield(.message(message))
    }

    /// Delivers one CLI stdout line, decoded as the SDK decodes it.
    func push(jsonLine: String) {
        guard let message = Message(jsonLine: Data(jsonLine.utf8)) else { return }
        push(message)
    }

    func push(_ event: SessionEvent) {
        continuation.yield(event)
    }

    /// Asks for tool permission; returns the request so the test can find it
    /// in the runtime's `pendingPermissions`. `onRespond` sees the answer.
    @discardableResult
    func requestPermission(
        toolName: String, input: JSONValue, id: String = UUID().uuidString,
        onRespond: @escaping @Sendable (PermissionDecision) -> Void = { _ in }
    ) -> PermissionRequest {
        let request = PermissionRequest(id: id, toolName: toolName, input: input, onRespond: onRespond)
        continuation.yield(.permissionRequest(request))
        return request
    }

    /// The process ends: pending calls fail, then `.exited` closes the stream.
    func simulateExit(code: Int32, stderr: String = "") {
        let termination = Termination(exitCode: code, stderr: stderr)
        let error = AgentSDKError.processExited(termination)
        pendingStart?.resume(throwing: error)
        pendingStart = nil
        pendingInterrupts.forEach { $0.continuation.resume(throwing: error) }
        pendingInterrupts = []
        pendingContextUsage.forEach { $0.continuation.resume(throwing: error) }
        pendingContextUsage = []
        pendingSideQuestions.forEach { $0.continuation.resume(throwing: error) }
        pendingSideQuestions = []
        continuation.yield(.exited(termination))
        continuation.finish()
    }
}

#endif

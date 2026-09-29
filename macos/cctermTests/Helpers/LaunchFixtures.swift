import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// A stand-in for `claude --version`: answers by the launch command, records
/// what it was asked, and can hold an answer until a test lets it go.
final class FakeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CLIConfiguration] = []
    private var failures: [String?: Error] = [:]
    private var gates: [String?: Gate] = [:]
    private var callback: (@Sendable (CLIConfiguration) -> Void)?

    /// What was asked, in order — the configuration as the probe got it.
    var calls: [CLIConfiguration] { lock.withLock { recorded } }

    /// Runs `body` on each call, after it is recorded.
    func onCall(_ body: @escaping @Sendable (CLIConfiguration) -> Void) {
        lock.withLock { callback = body }
    }

    /// Makes the launch command `command` fail with `error`.
    func fail(_ command: String?, with error: Error) {
        lock.withLock { failures[command] = error }
    }

    /// Makes the launch command `command` answer again.
    func succeed(_ command: String?) {
        lock.withLock { failures[command] = nil }
    }

    /// Holds the answer for `command` until the returned gate opens.
    func hold(_ command: String?) -> Gate {
        let gate = Gate()
        lock.withLock { gates[command] = gate }
        return gate
    }

    var probe: LaunchCheckService.Probe {
        { [self] configuration in try await answer(configuration) }
    }

    private func answer(_ configuration: CLIConfiguration) async throws -> CLIVersion {
        let call: Call = lock.withLock {
            recorded.append(configuration)
            let command = configuration.customCommand
            return Call(gate: gates[command], failure: failures[command], callback: callback)
        }
        call.callback?(configuration)
        await call.gate?.wait()
        if let failure = call.failure { throw failure }
        return Self.version(of: configuration.customCommand)
    }

    /// What one call found under the lock.
    private struct Call: Sendable {
        var gate: Gate?
        var failure: Error?
        var callback: (@Sendable (CLIConfiguration) -> Void)?
    }

    /// What the fake reports for `command`.
    static func version(of command: String?) -> CLIVersion {
        CLIVersion(executable: command ?? "/usr/local/bin/claude", version: "2.1.0")
    }
}

/// A door a test holds shut and then opens.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

extension XCTestCase {
    /// Waits until `publisher` has delivered a value `predicate` accepts —
    /// including the one it delivers on subscribing.
    @MainActor
    func waitFor<P: Publisher>(
        _ publisher: P, file: StaticString = #filePath, line: UInt = #line,
        where predicate: @escaping (P.Output) -> Bool
    ) async where P.Failure == Never {
        let reached = expectation(description: "publisher reached the value")
        reached.assertForOverFulfill = false
        let subscription = publisher.sink { if predicate($0) { reached.fulfill() } }
        await fulfillment(of: [reached], timeout: 10)
        subscription.cancel()
    }

    /// Everything `publisher` delivers from now on, in order, until the
    /// returned box is dropped.
    @MainActor
    func record<P: Publisher>(_ publisher: P) -> Recording<P.Output> where P.Failure == Never {
        Recording(publisher)
    }
}

/// The values a publisher delivered, in order.
@MainActor
final class Recording<Value> {
    private(set) var values: [Value] = []
    private var subscription: AnyCancellable?

    init<P: Publisher>(_ publisher: P) where P.Output == Value, P.Failure == Never {
        subscription = publisher.sink { [weak self] in self?.values.append($0) }
    }
}

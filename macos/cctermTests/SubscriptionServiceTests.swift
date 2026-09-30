import AgentSDK
import Combine
import XCTest

@testable import ccterm

// Combine has a `Subscription` too.
private typealias Subscription = ccterm.Subscription

/// ``SubscriptionService`` follows how the CLI is launched: each new launch
/// resets the login to unknown and reads it again, an answer for an earlier
/// launch is dropped, and sign-in and sign-out use the latest launch.
@MainActor
final class SubscriptionServiceTests: XCTestCase {
    private let configurations = PassthroughSubject<CLIConfiguration, Never>()
    private let auth = RecordingAuth()

    private func service() -> SubscriptionService {
        SubscriptionService(auth: auth, configurations: configurations.eraseToAnyPublisher())
    }

    private static func launch(_ command: String) -> CLIConfiguration {
        CLIConfiguration(customCommand: command)
    }

    private static func subscription(_ command: String) -> Subscription {
        Subscription(email: "\(command)@example.com", organization: nil, plan: nil, method: "claude.ai")
    }

    func testEachNewLaunchResetsAndReadsTheLoginAgain() async {
        let service = service()
        XCTAssertEqual(service.state, .unknown)
        let states = record(service.$state)

        configurations.send(Self.launch("orange"))
        await waitFor(service.$state) { $0 == .signedIn(Self.subscription("orange")) }
        configurations.send(Self.launch("blue"))
        XCTAssertEqual(service.state, .unknown, "what was read described another launch")
        await waitFor(service.$state) { $0 == .signedIn(Self.subscription("blue")) }

        XCTAssertEqual(
            states.values,
            [
                .unknown, .signedIn(Self.subscription("orange")), .unknown, .signedIn(Self.subscription("blue")),
            ])
        XCTAssertEqual(auth.reads.map(\.customCommand), ["orange", "blue"])
    }

    func testTheSameLaunchAgainReadsNothing() async {
        let service = service()
        configurations.send(Self.launch("orange"))
        await waitFor(service.$state) { $0 == .signedIn(Self.subscription("orange")) }
        configurations.send(Self.launch("orange"))
        XCTAssertEqual(service.state, .signedIn(Self.subscription("orange")))
        XCTAssertEqual(auth.reads.count, 1)
    }

    func testAnAnswerForAnEarlierLaunchIsDropped() async {
        let gate = auth.hold("slow")
        let started = expectation(description: "the slow read started")
        auth.onRead = { if $0.customCommand == "slow" { started.fulfill() } }
        let service = service()
        let states = record(service.$state)

        configurations.send(Self.launch("slow"))
        await fulfillment(of: [started], timeout: 10)
        configurations.send(Self.launch("fast"))
        await waitFor(service.$state) { $0 == .signedIn(Self.subscription("fast")) }
        await gate.open()
        // A later read finishes after the stale one has been handled.
        configurations.send(Self.launch("last"))
        await waitFor(service.$state) { $0 == .signedIn(Self.subscription("last")) }

        XCTAssertFalse(states.values.contains(.signedIn(Self.subscription("slow"))))
    }

    func testRefreshReadsForTheLatestLaunch() async {
        let service = service()
        configurations.send(Self.launch("orange"))
        await service.refresh()
        XCTAssertEqual(service.state, .signedIn(Self.subscription("orange")))
        XCTAssertEqual(auth.reads.last?.customCommand, "orange")
        XCTAssertGreaterThanOrEqual(auth.reads.count, 1)
    }

    func testSigningInAndOutUseTheLatestLaunch() async throws {
        let service = service()
        configurations.send(Self.launch("orange"))
        configurations.send(Self.launch("blue"))

        service.signIn()
        await waitFor(service.$state) { $0 == .signedIn(Self.subscription("blue")) }
        XCTAssertEqual(auth.signIns.map(\.customCommand), ["blue"])

        try await service.signOut()
        XCTAssertEqual(auth.signOuts.map(\.customCommand), ["blue"])
        XCTAssertEqual(service.state, .signedOut)
    }
}

/// A ``SubscriptionAuth`` that answers with an account named after the launch
/// command, and records each call.
private final class RecordingAuth: SubscriptionAuth, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedReads: [CLIConfiguration] = []
    private var recordedSignIns: [CLIConfiguration] = []
    private var recordedSignOuts: [CLIConfiguration] = []
    private var gates: [String: Gate] = [:]
    private var readCallback: (@Sendable (CLIConfiguration) -> Void)?

    var reads: [CLIConfiguration] { lock.withLock { recordedReads } }
    var signIns: [CLIConfiguration] { lock.withLock { recordedSignIns } }
    var signOuts: [CLIConfiguration] { lock.withLock { recordedSignOuts } }

    var onRead: (@Sendable (CLIConfiguration) -> Void)? {
        get { lock.withLock { readCallback } }
        set { lock.withLock { readCallback = newValue } }
    }

    func hold(_ command: String) -> Gate {
        let gate = Gate()
        lock.withLock { gates[command] = gate }
        return gate
    }

    func current(_ configuration: CLIConfiguration) async throws -> Subscription? {
        let (gate, callback) = lock.withLock {
            recordedReads.append(configuration)
            return (gates[configuration.customCommand ?? ""], readCallback)
        }
        callback?(configuration)
        await gate?.wait()
        let name = configuration.customCommand ?? ""
        return Subscription(email: "\(name)@example.com", organization: nil, plan: nil, method: "claude.ai")
    }

    func signIn(_ configuration: CLIConfiguration) -> AsyncThrowingStream<URL, Error> {
        lock.withLock { recordedSignIns.append(configuration) }
        return AsyncThrowingStream { $0.finish() }
    }

    func signOut(_ configuration: CLIConfiguration) async throws {
        lock.withLock { recordedSignOuts.append(configuration) }
    }
}

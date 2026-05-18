import AgentSDK
import XCTest

@testable import ccterm

/// Verifies `SessionRuntime` routes outgoing operations through the
/// injected `CLIClient`, not through a hard-wired `AgentSDK.Session`.
///
/// The handle's runtime contract is exercised end-to-end against
/// `FakeCLIClient`:
/// - `send(...)` defers the write until bootstrap completes and then
///   flushes the queued entry via `sendMessage(_:extra:)`.
/// - `setModel` / `setEffort` / `setPermissionMode` / `setFastMode`
///   forward to the client when attached.
/// - `interrupt()` reaches the client when running.
/// - `stop()` calls `close()`.
///
/// Each test drives the handle the way production would (`send` /
/// `set*` / `interrupt`) and asserts on calls captured by the fake.
@MainActor
final class SessionRuntimeCLIWiringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Pair a `SessionRuntime` with a fake CLIClient. Captures the fake
    /// so a test can drive it (push messages, complete initialize, ...)
    /// and assert on recorded calls.
    ///
    /// The wiring goes directly through `SessionRuntime.init` rather
    /// than the manager's `Session` façade — this test class exercises
    /// the runtime's CLI contract specifically (send → flush, set* →
    /// RPC, start failure → failLaunch), and the façade just forwards
    /// to whatever the runtime does. The façade-level tests live in
    /// `SessionFacadeTests` and `SessionPromotionTests`.
    private func makeRuntime(sessionId: String = UUID().uuidString) -> (SessionRuntime, FakeCLIClient) {
        let fake = FakeCLIClient()
        let runtime = SessionRuntime(
            sessionId: sessionId,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        runtime.config.cwd = "/tmp/cli-client-tests"
        return (runtime, fake)
    }

    /// Drive bootstrap to the "idle, attached" state. After this returns
    /// `runtime.cliClient === fake` and any queued user entries are
    /// flushed.
    private func bootstrap(_ runtime: SessionRuntime, _ fake: FakeCLIClient) async {
        runtime.activate()
        // `bootstrap` is a detached `Task { @MainActor … }` kicked off
        // synchronously from `ensureStarted`. Yield once so it can pick
        // up the actor and reach the `initialize` continuation.
        for _ in 0..<8 {
            await Task.yield()
            if !fake.initializeCalls.isEmpty { break }
        }
        XCTAssertFalse(fake.initializeCalls.isEmpty, "bootstrap should have called initialize")
        fake.completeInitialize(with: nil)
        // Let bootstrap resume after the continuation completes.
        for _ in 0..<8 {
            await Task.yield()
            if runtime.status == .idle { break }
        }
    }

    // MARK: - Tests

    func testSendDefersUntilBootstrapThenFlushes() async {
        let (runtime, fake) = makeRuntime()
        runtime.send(text: "hello")

        XCTAssertTrue(
            fake.sendCalls.isEmpty,
            "send() before bootstrap must not write to CLI yet")
        XCTAssertEqual(fake.startCalls, 0, "client.start should not run before bootstrap")

        await bootstrap(runtime, fake)

        XCTAssertEqual(fake.startCalls, 1)
        XCTAssertEqual(fake.sendCalls.count, 1, "queued entry should flush once bootstrap idle")
        XCTAssertEqual(fake.sendCalls.first?.text, "hello")
        XCTAssertEqual(runtime.status, .idle)
    }

    func testSendAfterBootstrapWritesImmediately() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        runtime.send(text: "second")

        XCTAssertEqual(fake.sendCalls.count, 1)
        XCTAssertEqual(fake.sendCalls.first?.text, "second")
    }

    func testSetModelEffortPermissionForwardWhenAttached() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        runtime.setModel("claude-sonnet-4-6")
        runtime.setEffort(.high)
        runtime.setPermissionMode(.acceptEdits)
        runtime.setFastMode(true)

        XCTAssertEqual(fake.modelCalls, ["claude-sonnet-4-6"])
        XCTAssertEqual(fake.effortCalls, [.high])
        XCTAssertEqual(fake.permissionModeCalls, [PermissionMode.acceptEdits.toSDK()])
        XCTAssertEqual(fake.fastModeCalls, [true])
    }

    func testSetModelWhileDetachedDoesNotTouchClient() {
        let (runtime, fake) = makeRuntime()
        // status = .notStarted → no client attached yet
        runtime.setModel("claude-sonnet-4-6")

        XCTAssertEqual(runtime.model, "claude-sonnet-4-6")
        XCTAssertTrue(fake.modelCalls.isEmpty, "setModel must not RPC before bootstrap")
    }

    func testInterruptForwardsToClientWhenRunning() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        runtime.send(text: "trigger")
        XCTAssertTrue(runtime.isRunning)
        XCTAssertEqual(fake.sendCalls.count, 1)

        runtime.interrupt()

        XCTAssertEqual(fake.interruptCalls.count, 1, "interrupt should reach the client")
        XCTAssertFalse(runtime.isRunning, "interrupt zeroes turn count synchronously")
    }

    func testStopClosesClient() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        XCTAssertEqual(fake.closeCalls, 0)

        runtime.stop()

        XCTAssertEqual(fake.closeCalls, 1)
    }

    func testStartFailureFunnelsThroughFailLaunch() async {
        let (runtime, fake) = makeRuntime()
        struct DummyError: Error {}
        fake.startError = DummyError()

        var captured: String?
        runtime.onLaunchFailure = { captured = $0 }

        runtime.activate()
        for _ in 0..<16 {
            await Task.yield()
            if runtime.status == .stopped { break }
        }

        XCTAssertEqual(runtime.status, .stopped)
        XCTAssertNotNil(captured, "onLaunchFailure should fire on start() throw")
        XCTAssertNil(runtime.cliClient, "failed launch must clear cliClient")
    }
}

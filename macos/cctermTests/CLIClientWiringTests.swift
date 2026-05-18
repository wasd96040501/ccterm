import AgentSDK
import XCTest

@testable import ccterm

/// Verifies `SessionHandle2` routes outgoing operations through the
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
final class CLIClientWiringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Pair a handle with a fake CLIClient. Captures the fake so a test
    /// can drive it (push messages, complete initialize, ...) and
    /// assert on recorded calls.
    ///
    /// Factory injection now lives on `SessionManager2`. Each test stands
    /// up its own manager with the fake wired in, so handles produced by
    /// the manager inherit the test client.
    private func makeHandle(sessionId: String = UUID().uuidString) -> (SessionHandle2, FakeCLIClient) {
        let fake = FakeCLIClient()
        let manager = SessionManager2(
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        let handle = manager.prepareDraft(sessionId)
        handle.setCwd("/tmp/cli-client-tests")
        return (handle, fake)
    }

    /// Drive bootstrap to the "idle, attached" state. After this returns
    /// `handle.cliClient === fake` and any queued user entries are
    /// flushed.
    private func bootstrap(_ handle: SessionHandle2, _ fake: FakeCLIClient) async {
        handle.activate()
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
            if handle.status == .idle { break }
        }
    }

    // MARK: - Tests

    func testSendDefersUntilBootstrapThenFlushes() async {
        let (handle, fake) = makeHandle()
        handle.send(text: "hello")

        XCTAssertTrue(
            fake.sendCalls.isEmpty,
            "send() before bootstrap must not write to CLI yet")
        XCTAssertEqual(fake.startCalls, 0, "client.start should not run before bootstrap")

        await bootstrap(handle, fake)

        XCTAssertEqual(fake.startCalls, 1)
        XCTAssertEqual(fake.sendCalls.count, 1, "queued entry should flush once bootstrap idle")
        XCTAssertEqual(fake.sendCalls.first?.text, "hello")
        XCTAssertEqual(handle.status, .idle)
    }

    func testSendAfterBootstrapWritesImmediately() async {
        let (handle, fake) = makeHandle()
        await bootstrap(handle, fake)

        handle.send(text: "second")

        XCTAssertEqual(fake.sendCalls.count, 1)
        XCTAssertEqual(fake.sendCalls.first?.text, "second")
    }

    func testSetModelEffortPermissionForwardWhenAttached() async {
        let (handle, fake) = makeHandle()
        await bootstrap(handle, fake)

        handle.setModel("claude-sonnet-4-6")
        handle.setEffort(.high)
        handle.setPermissionMode(.acceptEdits)
        handle.setFastMode(true)

        XCTAssertEqual(fake.modelCalls, ["claude-sonnet-4-6"])
        XCTAssertEqual(fake.effortCalls, [.high])
        XCTAssertEqual(fake.permissionModeCalls, [PermissionMode.acceptEdits.toSDK()])
        XCTAssertEqual(fake.fastModeCalls, [true])
    }

    func testSetModelWhileDetachedDoesNotTouchClient() {
        let (handle, fake) = makeHandle()
        // status = .notStarted → no client attached yet
        handle.setModel("claude-sonnet-4-6")

        XCTAssertEqual(handle.model, "claude-sonnet-4-6")
        XCTAssertTrue(fake.modelCalls.isEmpty, "setModel must not RPC before bootstrap")
    }

    func testInterruptForwardsToClientWhenRunning() async {
        let (handle, fake) = makeHandle()
        await bootstrap(handle, fake)

        handle.send(text: "trigger")
        XCTAssertTrue(handle.isRunning)
        XCTAssertEqual(fake.sendCalls.count, 1)

        handle.interrupt()

        XCTAssertEqual(fake.interruptCalls.count, 1, "interrupt should reach the client")
        XCTAssertFalse(handle.isRunning, "interrupt zeroes turn count synchronously")
    }

    func testStopClosesClient() async {
        let (handle, fake) = makeHandle()
        await bootstrap(handle, fake)
        XCTAssertEqual(fake.closeCalls, 0)

        handle.stop()

        XCTAssertEqual(fake.closeCalls, 1)
    }

    func testStartFailureFunnelsThroughFailLaunch() async {
        let (handle, fake) = makeHandle()
        struct DummyError: Error {}
        fake.startError = DummyError()

        var captured: String?
        handle.onLaunchFailure = { captured = $0 }

        handle.activate()
        for _ in 0..<16 {
            await Task.yield()
            if handle.status == .stopped { break }
        }

        XCTAssertEqual(handle.status, .stopped)
        XCTAssertNotNil(captured, "onLaunchFailure should fire on start() throw")
        XCTAssertNil(handle.cliClient, "failed launch must clear cliClient")
    }
}

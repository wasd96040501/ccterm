import AgentSDK
import XCTest

@testable import ccterm

/// Locks in the `isRunning` contract on `SessionRuntime`:
///
/// - `send` flips it synchronously even before bootstrap completes.
/// - `.assistant` from the CLI flips it true (covers stray late
///   assistants and CLI-spontaneous follow-up turns — the real
///   background-bash scenario captured in
///   `swift run DumpSmoke` with `SMOKE_SCENARIO=bgjob`).
/// - `.result` from the CLI flips it false.
/// - `interrupt` / process exit / launch failure clear it.
///
/// Tests drive `SessionRuntime` directly through `FakeCLIClient`; no
/// real CLI subprocess, no real Anthropic round-trips.
@MainActor
final class SessionRuntimeIsRunningTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func makeRuntime() -> (SessionRuntime, FakeCLIClient) {
        let fake = FakeCLIClient()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        runtime.config.cwd = "/tmp/isrunning-tests"
        return (runtime, fake)
    }

    /// Drive bootstrap to attached + `.idle`.
    private func bootstrap(_ runtime: SessionRuntime, _ fake: FakeCLIClient) async {
        runtime.activate()
        for _ in 0..<16 {
            await Task.yield()
            if !fake.initializeCalls.isEmpty { break }
        }
        XCTAssertFalse(fake.initializeCalls.isEmpty, "bootstrap should call initialize")
        fake.completeInitialize(with: nil)
        for _ in 0..<16 {
            await Task.yield()
            if runtime.status == .idle { break }
        }
        XCTAssertEqual(runtime.status, .idle)
    }

    /// Push a Message2 into the runtime and wait until receive() has
    /// actually applied it. `attachCallbacks` wraps `onMessage` in
    /// `Task { @MainActor in receive(...) }`, so direct asserts after
    /// `pushMessage` race the receive.
    private func push(
        _ message: Message2,
        into fake: FakeCLIClient
    ) async {
        fake.pushMessage(message)
        // A single yield is enough to drain the @MainActor task the
        // SDK shim schedules; loop a few times in case the receive
        // path itself schedules further work.
        for _ in 0..<4 { await Task.yield() }
    }

    // MARK: - Happy path

    func testHappyPathFlipsOnSendAndOffOnResult() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        XCTAssertFalse(runtime.isRunning)

        runtime.send(text: "hi")
        XCTAssertTrue(runtime.isRunning, "send must flip isRunning synchronously")

        await push(Message2Fixtures.assistantText("response"), into: fake)
        XCTAssertTrue(runtime.isRunning, "assistant keeps it on")

        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(runtime.isRunning, ".result must flip it off")
    }

    // MARK: - Stray late assistant (post-turn) self-heal

    /// Mirrors the background-bash scenario captured by
    /// `DumpSmoke` (SMOKE_SCENARIO=bgjob): a turn closes with `.result`,
    /// then later (5s in real life) the CLI streams a fresh `.assistant`
    /// for a follow-up turn it kicked off on its own. The spinner must
    /// come back on so the user sees something is happening; the next
    /// `.result` closes it cleanly.
    func testAssistantAfterResultSelfHealsIsRunning() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        runtime.send(text: "kick off background")
        await push(Message2Fixtures.assistantText("kicking off…"), into: fake)
        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(runtime.isRunning, "turn 1 closed")

        // CLI spontaneously starts a follow-up turn.
        await push(Message2Fixtures.assistantText("background finished"), into: fake)
        XCTAssertTrue(runtime.isRunning, "late assistant must restart spinner")

        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(runtime.isRunning, "second .result closes the follow-up turn")
    }

    // MARK: - Multi-send / single-result no-stuck

    /// Old counter design stuck on `pendingTurnCount = 1` if two sends
    /// produced only one CLI turn. With `.result` as authoritative
    /// turn-end, the spinner clears regardless.
    func testTwoSendsOneResultClears() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        runtime.send(text: "msg 1")
        runtime.send(text: "msg 2")
        XCTAssertTrue(runtime.isRunning)
        XCTAssertEqual(fake.sendCalls.count, 2)

        await push(Message2Fixtures.assistantText("merged reply"), into: fake)
        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(
            runtime.isRunning,
            "one .result must end the turn even when multiple sends were in flight")
    }

    // MARK: - Stray .result with assistant still streaming

    /// Even if a `.result` arrives early / out-of-order, a subsequent
    /// `.assistant` must restore the spinner (mirrors the same self-
    /// heal as the post-turn case, just within one turn).
    func testStrayResultThenAssistantRestores() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        runtime.send(text: "x")
        // Out-of-order .result.
        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(runtime.isRunning)

        await push(Message2Fixtures.assistantText("real reply"), into: fake)
        XCTAssertTrue(runtime.isRunning, "later assistant rescues isRunning")

        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(runtime.isRunning)
    }

    // MARK: - Pre-bootstrap send

    /// `send` while the CLI is still starting up must still flip the
    /// spinner so the InputBar swaps to stop immediately. The queued
    /// entry then flushes on bootstrap, and the normal CLI stream
    /// drives subsequent transitions.
    func testSendBeforeBootstrapFlipsIsRunning() async {
        let (runtime, fake) = makeRuntime()
        XCTAssertFalse(runtime.isRunning)

        runtime.send(text: "early")
        XCTAssertTrue(runtime.isRunning, "send must flip even pre-bootstrap")
        XCTAssertTrue(fake.sendCalls.isEmpty, "no CLI write until bootstrap idle")

        await bootstrap(runtime, fake)
        XCTAssertEqual(fake.sendCalls.count, 1, "queued entry flushed at bootstrap idle")
        XCTAssertTrue(runtime.isRunning)

        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(runtime.isRunning)
    }

    // MARK: - Cleanup paths

    func testInterruptClearsIsRunning() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        runtime.send(text: "x")
        XCTAssertTrue(runtime.isRunning)

        runtime.interrupt()
        XCTAssertFalse(runtime.isRunning)
        XCTAssertEqual(fake.interruptCalls.count, 1)
    }

    func testProcessExitClearsIsRunning() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        runtime.send(text: "x")
        XCTAssertTrue(runtime.isRunning)

        fake.simulateProcessExit(code: 1)
        for _ in 0..<16 {
            await Task.yield()
            if !runtime.isRunning { break }
        }
        XCTAssertFalse(runtime.isRunning)
    }

    func testLaunchFailureClearsIsRunning() async {
        let (runtime, fake) = makeRuntime()
        struct DummyError: Error {}
        fake.startError = DummyError()

        runtime.send(text: "x")
        XCTAssertTrue(runtime.isRunning, "send flips first; failure unwinds")

        // Bootstrap was kicked off by `send`'s `ensureStarted()`.
        for _ in 0..<32 {
            await Task.yield()
            if runtime.status == .stopped { break }
        }
        XCTAssertEqual(runtime.status, .stopped)
        XCTAssertFalse(runtime.isRunning, "failLaunch must clear isRunning")
    }

    // MARK: - system.init wake-up

    /// `.system(.init)` arriving past bootstrap (status >= .idle) is the
    /// CLI announcing a new turn. It fires ~one frame before the
    /// turn's first `.assistant`, so we use it as the earlier wake-up.
    func testTurnBoundaryInitFlipsIsRunning() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        runtime.send(text: "go")
        await push(Message2Fixtures.assistantText("a"), into: fake)
        await push(Message2Fixtures.result(), into: fake)
        XCTAssertFalse(runtime.isRunning, "turn 1 closed")

        // CLI re-inits at the start of a spontaneous follow-up turn.
        await push(Message2Fixtures.systemInit(), into: fake)
        XCTAssertTrue(
            runtime.isRunning,
            "turn-boundary system.init must relight the spinner ahead of assistant")
    }

    /// The bootstrap `.system(.init)` arrives while `status == .starting`
    /// and must NOT flip isRunning. If the user hasn't sent anything
    /// yet, the spinner stays off; if they have, `send` flipped it
    /// true already.
    func testBootstrapInitDoesNotForceIsRunning() async {
        let (runtime, fake) = makeRuntime()

        // Drive bootstrap up to the initialize-response continuation,
        // *without* sending a user message. status is .starting.
        runtime.activate()
        for _ in 0..<16 {
            await Task.yield()
            if !fake.initializeCalls.isEmpty { break }
        }
        XCTAssertEqual(runtime.status, .starting)
        XCTAssertFalse(runtime.isRunning)

        // Simulate the CLI pushing the bootstrap system.init.
        await push(Message2Fixtures.systemInit(), into: fake)

        XCTAssertFalse(
            runtime.isRunning,
            "bootstrap system.init (status == .starting) must not flip the spinner")
    }

    // MARK: - Replay must not flip isRunning

    /// JSONL replay feeds `.assistant` / `.result` through `receive`
    /// with `mode = .replay`. Those events are historical content, not
    /// live CLI signals, so they must not drive the live spinner.
    func testReplayDoesNotTouchIsRunning() {
        let (runtime, _) = makeRuntime()
        runtime.isRunning = false

        runtime.receive(Message2Fixtures.assistantText("ancient"), mode: .replay)
        XCTAssertFalse(runtime.isRunning, "replay assistant must not flip on")

        runtime.isRunning = true
        runtime.receive(Message2Fixtures.result(), mode: .replay)
        XCTAssertTrue(runtime.isRunning, "replay result must not flip off")
    }
}

import AgentSDK
import XCTest

@testable import ccterm

/// `SessionManager.shutdownAllAsync()` is the app-quit cleanup hook —
/// `AppDelegate.applicationShouldTerminate` awaits it so every active
/// CLI subprocess gets a chance to flush its session file before
/// `NSApplication` tears down the process.
///
/// Two properties matter:
/// - **It calls `closeAsync` on every cached session.** Sessions with a
///   live runtime route through to `CLIClient.closeAsync`; sessions in
///   `.notStarted` / `.stopped` self-skip inside the runtime so the
///   manager doesn't need a per-session status check.
/// - **It runs them in parallel, not serially.** With N sessions the
///   wall time has to scale with the slowest CLI, not the sum — quitting
///   an app with a dozen sessions has to take ~one graceful timeout,
///   not twelve.
@MainActor
final class SessionManagerShutdownTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Build a manager that hands out a `FakeCLIClient` per `Session`,
    /// pre-seed `count` records, and bootstrap every session to `.idle`
    /// so its runtime holds a live `cliClient`. Returns the manager and
    /// the captured fakes in creation order.
    private func makeBootstrappedManager(count: Int) async -> (SessionManager, [FakeCLIClient]) {
        let repo = InMemorySessionRepository()
        let ids = (0..<count).map { _ in UUID().uuidString }
        for id in ids {
            repo.save(
                SessionRecord(
                    sessionId: id,
                    title: "session-\(id.prefix(4))",
                    cwd: "/tmp/shutdown-tests",
                    status: .created
                ))
        }

        // The factory is `@MainActor`, so writes to `fakes` are
        // serialized; no extra synchronization needed.
        var fakes: [FakeCLIClient] = []
        let factory: CLIClientFactory = { _ in
            let f = FakeCLIClient()
            fakes.append(f)
            return f
        }
        let manager = SessionManager(repository: repo, cliClientFactory: factory)

        let sessions = ids.compactMap { manager.session($0) }
        XCTAssertEqual(sessions.count, count)

        for session in sessions { session.activate() }

        // Drive each runtime's bootstrap to `.idle`. Bootstrap is a
        // detached `Task { @MainActor … }`, so we yield until every
        // fake has its `initialize` call recorded, complete them all,
        // then yield again until every status is `.idle`.
        for _ in 0..<64 {
            await Task.yield()
            if fakes.count == count, fakes.allSatisfy({ !$0.initializeCalls.isEmpty }) { break }
        }
        XCTAssertEqual(fakes.count, count, "every session should have produced a fake")
        for fake in fakes { fake.completeInitialize(with: nil) }
        for _ in 0..<64 {
            await Task.yield()
            if sessions.allSatisfy({ $0.runtime?.status == .idle }) { break }
        }
        XCTAssertTrue(
            sessions.allSatisfy { $0.runtime?.status == .idle },
            "every session should reach .idle before the test exercises shutdown")
        return (manager, fakes)
    }

    /// `shutdownAllAsync` reaches every cached session. After it returns
    /// each fake has recorded exactly one `closeAsync` call. Sanity
    /// check before the parallelism assertion below.
    func testShutdownAllAsyncClosesEverySession() async {
        let (manager, fakes) = await makeBootstrappedManager(count: 3)

        await manager.shutdownAllAsync()

        for fake in fakes {
            XCTAssertEqual(fake.closeAsyncCalls, 1, "every session's CLI should be closed exactly once")
        }
    }

    /// Parallelism proof: gate every fake's `closeAsync` on a per-fake
    /// continuation so none of them can complete until we resume it.
    /// If `shutdownAllAsync` ran serially, only the first fake's hook
    /// would enter and the shared counter would stop at 1 — the
    /// expectation would never fulfill and the test times out.
    ///
    /// With parallel `withTaskGroup` dispatch all three hooks enter
    /// concurrently, the counter reaches `count`, the expectation
    /// fulfills, and we then resume every continuation so the shutdown
    /// task can finish cleanly.
    func testShutdownAllAsyncRunsClosesInParallel() async {
        let (manager, fakes) = await makeBootstrappedManager(count: 3)

        var entered = 0
        var continuations: [CheckedContinuation<Void, Never>] = []
        let allEntered = expectation(description: "every closeAsync entered concurrently")
        let total = fakes.count

        for fake in fakes {
            fake.closeAsyncHook = {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        entered += 1
                        continuations.append(cont)
                        if entered == total {
                            allEntered.fulfill()
                        }
                    }
                }
            }
        }

        let shutdownTask = Task { @MainActor in
            await manager.shutdownAllAsync()
        }

        await fulfillment(of: [allEntered], timeout: 5.0)
        XCTAssertEqual(
            entered, total,
            "all closeAsync hooks must be in-flight before any is resumed (proves parallelism)")

        for cont in continuations { cont.resume() }
        await shutdownTask.value
    }
}

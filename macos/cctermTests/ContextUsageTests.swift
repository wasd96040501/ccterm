import AgentSDK
import XCTest

@testable import ccterm

/// `Session.requestContextUsage(...)` end-to-end: the request goes through
/// the runtime into the `CLIClient`, and the cached response is exposed
/// back on the façade. Tests drive a real `SessionRuntime` constructed with
/// a `FakeCLIClient` factory and activate it so the production
/// `activate → start → cliClient` wiring fires. (Decoding the response is
/// covered by the AgentSDK package's own `ContextUsageTests`.)
@MainActor
final class ContextUsageTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRequestContextUsageForwardsToCLIAndCachesResponse() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        XCTAssertNil(session.contextUsage)
        XCTAssertFalse(session.isFetchingContextUsage)

        let request = session.requestContextUsage()
        XCTAssertTrue(session.isFetchingContextUsage)
        await yieldUntil { fake.contextUsageCalls == 1 }
        XCTAssertEqual(fake.contextUsageCalls, 1)

        fake.completeContextUsage(
            .success(
                try usage([
                    "rawMaxTokens": 500_000,
                    "totalTokens": 12_345,
                    "percentage": 2,
                    "categories": [["name": "Messages", "tokens": 12_345]],
                ])))
        await request?.value

        XCTAssertEqual(session.contextUsage?.rawMaxTokens, 500_000)
        XCTAssertEqual(session.contextUsage?.totalTokens, 12_345)
        XCTAssertNotNil(session.contextUsageFetchedAt)
        XCTAssertFalse(session.isFetchingContextUsage)
    }

    func testConcurrentRequestsAreCoalescedIntoOneCLICall() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let first = session.requestContextUsage()
        let second = session.requestContextUsage()
        await yieldUntil { fake.contextUsageCalls == 1 }

        XCTAssertEqual(
            fake.contextUsageCalls, 1,
            "second caller should attach to the in-flight request, not fire a new one")

        fake.completeContextUsage(.success(try usage(["rawMaxTokens": 1])))
        await first?.value
        await second?.value
        XCTAssertFalse(session.isFetchingContextUsage)
    }

    func testFailureLeavesCacheUntouched() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        // Seed an earlier successful response so we can confirm a failed
        // request does not wipe the cache.
        let seed = session.requestContextUsage()
        await yieldUntil { fake.contextUsageCalls == 1 }
        fake.completeContextUsage(.success(try usage(["rawMaxTokens": 100])))
        await seed?.value
        XCTAssertEqual(session.contextUsage?.rawMaxTokens, 100)

        struct Unsupported: Error {}
        let failing = session.requestContextUsage()
        await yieldUntil { fake.contextUsageCalls == 2 }
        fake.completeContextUsage(.failure(Unsupported()))
        await failing?.value
        XCTAssertEqual(session.contextUsage?.rawMaxTokens, 100, "cache stays put on failure")
        XCTAssertFalse(session.isFetchingContextUsage)
    }

    /// A CLI that never answers doesn't wedge the ring: the request gives up
    /// after its timeout and clears the fetching flag.
    func testUnansweredRequestTimesOut() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let request = session.requestContextUsage(timeout: 0.05)
        await request?.value

        XCTAssertFalse(session.isFetchingContextUsage)
        XCTAssertNil(session.contextUsage)
    }

    /// The context-usage cache lives in the `@Observable`
    /// `ContextUsageCache` reference owned by the runtime. The request
    /// lands on a **later** runloop tick and writes `contextUsage` /
    /// `contextUsageFetchedAt` / `isFetchingContextUsage` (whole-value
    /// assignments). Reading `session.contextUsage` (→
    /// `runtime.contextUsageCache.contextUsage`) must register an
    /// observation that fires when that async write lands — otherwise the
    /// `ContextRingButton` popover would never refresh. Driven through the
    /// public façade.
    func testAsyncResponseTriggersObservationOnSessionContextUsage() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let request = session.requestContextUsage()
        await yieldUntil { fake.contextUsageCalls == 1 }

        let changed = expectation(description: "session.contextUsage observer fires on async landing")
        withObservationTracking {
            _ = session.contextUsage
        } onChange: {
            changed.fulfill()
        }
        fake.completeContextUsage(.success(try usage(["rawMaxTokens": 321, "totalTokens": 99])))

        await fulfillment(of: [changed], timeout: 2.0)
        await request?.value
        XCTAssertEqual(session.contextUsage?.rawMaxTokens, 321)
    }

    func testDraftSessionHasNothingToRequest() {
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        XCTAssertNil(session.requestContextUsage())
        XCTAssertNil(session.contextUsage)
    }

    // MARK: - Percentage rounding (matches the JS reference's Math.round)

    func testPercentageRoundsHalfUp() {
        XCTAssertEqual(Int((0.5).rounded()), 1)
        XCTAssertEqual(Int((9.74).rounded()), 10)
        XCTAssertEqual(Int((9.49).rounded()), 9)
        XCTAssertEqual(Int((99.6).rounded()), 100)
    }

    // MARK: - Helpers

    private func usage(_ json: JSONValue) throws -> ContextUsage {
        try json.decode(ContextUsage.self)
    }

    /// Build an `.active`-phase Session backed by `fake` and wait for
    /// the runtime to have wired `cliClient` to the fake (which is what
    /// production's `activate` → bootstrap → `start` → `cliClient = ...`
    /// chain produces). Lets the test then drive `requestContextUsage`
    /// through the public façade without touching internal state.
    private func makeActivatedSession(client fake: FakeCLIClient) async throws -> ccterm.Session {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        let record = SessionRecord(
            sessionId: sid,
            title: "ctx-test",
            cwd: NSTemporaryDirectory(),
            status: .created
        )
        repo.save(record)
        let session = ccterm.Session(
            record: record,
            repository: repo,
            cliClientFactory: { _ in fake }
        )
        session.activate()
        await yieldUntil { fake.isAwaitingStart }
        fake.completeStart()

        // Wait until cliClient is attached on the runtime (the production
        // code's only signal that the CLI is ready for control requests).
        let runtime = try XCTUnwrap(session.runtime)
        let attached = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { runtime.cliClient != nil }
            },
            object: nil
        )
        await fulfillment(of: [attached], timeout: 5.0)
        return session
    }
}

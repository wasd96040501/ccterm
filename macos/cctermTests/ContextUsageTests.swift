import AgentSDK
import XCTest

@testable import ccterm

/// Pure-logic tests for the `get_context_usage` plumbing.
///
/// Two surfaces are exercised:
///
/// 1. `AgentSDK.ContextUsage(json:)` — strong typing over the JSON
///    payload returned by the CLI (categories, memory files, MCP tools,
///    totals).
/// 2. `Session.requestContextUsage(...)` end-to-end — the request goes
///    through the runtime, into the `CLIClient`, and the cached
///    response is exposed back on the façade. Tests drive a real
///    `SessionRuntime` constructed with a `FakeCLIClient` factory and
///    activate it so the production `activate → start → cliClient`
///    wiring fires.
@MainActor
final class ContextUsageTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - ContextUsage JSON parsing

    func testParsesMinimalResponse() throws {
        let raw: [String: Any] = [
            "categories": [
                ["name": "Messages", "tokens": 74_600, "color": "purple"],
                ["name": "System tools", "tokens": 11_600, "color": "inactive"],
                ["name": "Autocompact buffer", "tokens": 33_000, "color": "inactive"],
                ["name": "Free space", "tokens": 869_600, "color": "promptBorder"],
            ],
            "totalTokens": 97_400,
            "maxTokens": 1_000_000,
            "rawMaxTokens": 1_000_000,
            "percentage": 10,
            "model": "claude-opus-4-7",
            "isAutoCompactEnabled": true,
            "memoryFiles": [],
            "mcpTools": [],
            "agents": [],
        ]
        let usage = try ContextUsage(json: raw)
        XCTAssertEqual(usage.totalTokens, 97_400)
        XCTAssertEqual(usage.rawMaxTokens, 1_000_000)
        XCTAssertEqual(usage.percentage, 10)
        XCTAssertEqual(usage.model, "claude-opus-4-7")
        XCTAssertTrue(usage.isAutoCompactEnabled)
        XCTAssertEqual(usage.categories.count, 4)
        XCTAssertEqual(usage.categories[0].name, "Messages")
        XCTAssertEqual(usage.categories[0].tokens, 74_600)
        XCTAssertFalse(usage.categories[0].isDeferred)
    }

    func testParsesDeferredFlagAndDetailLists() throws {
        let raw: [String: Any] = [
            "categories": [
                ["name": "System tools (deferred)", "tokens": 19_157, "isDeferred": true],
                ["name": "MCP tools (deferred)", "tokens": 1_855, "isDeferred": true],
            ],
            "rawMaxTokens": 1_000_000,
            "memoryFiles": [
                ["path": "/Users/u/CLAUDE.md", "type": "Project", "tokens": 7_900],
                ["path": "~/.claude/CLAUDE.md", "tokens": 382],
            ],
            "mcpTools": [
                ["name": "browser__navigate", "serverName": "browser", "tokens": 320, "isLoaded": false]
            ],
            "agents": [
                ["agentType": "Explore", "source": "built-in", "tokens": 250]
            ],
            "isAutoCompactEnabled": false,
        ]
        let usage = try ContextUsage(json: raw)
        XCTAssertTrue(usage.categories.allSatisfy(\.isDeferred))
        XCTAssertEqual(usage.memoryFiles.count, 2)
        XCTAssertEqual(usage.memoryFiles[0].path, "/Users/u/CLAUDE.md")
        XCTAssertEqual(usage.memoryFiles[0].type, "Project")
        XCTAssertEqual(usage.memoryFiles[0].tokens, 7_900)
        XCTAssertEqual(usage.memoryFiles[1].type, nil)
        XCTAssertEqual(usage.mcpTools.count, 1)
        XCTAssertEqual(usage.mcpTools[0].serverName, "browser")
        XCTAssertEqual(usage.mcpTools[0].isLoaded, false)
        XCTAssertEqual(usage.agents.count, 1)
        XCTAssertEqual(usage.agents[0].agentType, "Explore")
        XCTAssertFalse(usage.isAutoCompactEnabled)
    }

    func testToleratesMissingOptionalFields() throws {
        let usage = try ContextUsage(json: ["rawMaxTokens": 200_000])
        XCTAssertEqual(usage.rawMaxTokens, 200_000)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.percentage, 0)
        XCTAssertFalse(usage.isAutoCompactEnabled)
        XCTAssertTrue(usage.categories.isEmpty)
        XCTAssertTrue(usage.memoryFiles.isEmpty)
        XCTAssertNil(usage.model)
    }

    // MARK: - Session forwarding into CLIClient

    func testRequestContextUsageForwardsToCLIAndCachesResponse() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        XCTAssertNil(session.contextUsage)
        XCTAssertFalse(session.isFetchingContextUsage)

        let exp = expectation(description: "completion fires")
        session.requestContextUsage { outcome in
            if case .usage = outcome { exp.fulfill() } else { XCTFail("\(outcome)") }
        }

        XCTAssertEqual(fake.contextUsageCalls.count, 1)
        XCTAssertTrue(session.isFetchingContextUsage)

        let usage = try ContextUsage(json: [
            "rawMaxTokens": 500_000,
            "totalTokens": 12_345,
            "percentage": 2,
            "categories": [["name": "Messages", "tokens": 12_345]],
        ])
        fake.completeContextUsage(.usage(usage))
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(session.contextUsage?.rawMaxTokens, 500_000)
        XCTAssertEqual(session.contextUsage?.totalTokens, 12_345)
        XCTAssertNotNil(session.contextUsageFetchedAt)
        XCTAssertFalse(session.isFetchingContextUsage)
    }

    func testConcurrentRequestsAreCoalescedIntoOneCLICall() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let exp1 = expectation(description: "callback 1")
        let exp2 = expectation(description: "callback 2")
        session.requestContextUsage { _ in exp1.fulfill() }
        session.requestContextUsage { _ in exp2.fulfill() }

        XCTAssertEqual(
            fake.contextUsageCalls.count, 1,
            "second caller should attach to the in-flight request, not fire a new one")

        let usage = try ContextUsage(json: ["rawMaxTokens": 1])
        fake.completeContextUsage(.usage(usage))
        await fulfillment(of: [exp1, exp2], timeout: 2.0)
        XCTAssertFalse(session.isFetchingContextUsage)
    }

    func testUnsupportedOutcomeLeavesCacheUntouched() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        // Seed an earlier successful response so we can confirm
        // `.unsupported` does not wipe the cache.
        let seeded = try ContextUsage(json: ["rawMaxTokens": 100])
        let seedExp = expectation(description: "seed")
        session.requestContextUsage { _ in seedExp.fulfill() }
        fake.completeContextUsage(.usage(seeded))
        await fulfillment(of: [seedExp], timeout: 2.0)
        XCTAssertEqual(session.contextUsage?.rawMaxTokens, 100)

        let exp = expectation(description: "unsupported")
        session.requestContextUsage { outcome in
            if case .unsupported = outcome { exp.fulfill() } else { XCTFail("\(outcome)") }
        }
        fake.completeContextUsage(.unsupported)
        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(session.contextUsage?.rawMaxTokens, 100, "cache stays put on .unsupported")
        XCTAssertFalse(session.isFetchingContextUsage)
    }

    func testDraftSessionShortCircuitsToUnsupported() {
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        let exp = expectation(description: "unsupported")
        session.requestContextUsage { outcome in
            if case .unsupported = outcome { exp.fulfill() } else { XCTFail("\(outcome)") }
        }
        wait(for: [exp], timeout: 1.0)
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

        // Bootstrap is `Task.detached` — wait until cliClient is
        // attached on the runtime (the production code's only signal
        // that the CLI is ready for control requests). Use
        // `XCTNSPredicateExpectation` so we don't busy-poll under CI
        // load.
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

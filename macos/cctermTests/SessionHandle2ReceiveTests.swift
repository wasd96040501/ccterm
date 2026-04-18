import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2.receive(_:mode:)`. Uses two real jsonl fixtures to
/// exercise the full ingest path, plus a few hand-built messages for branch
/// coverage (lifecycle transitions, filters, presence).
@MainActor
final class SessionHandle2ReceiveTests: XCTestCase {

    // MARK: - Setup helpers

    private func makeHandle() -> SessionHandle2 {
        let stack = CoreDataStack(inMemory: true)
        let repo = SessionRepository(coreDataStack: stack)
        return SessionHandle2(sessionId: "receive-test", repository: repo)
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func loadFixture(_ filename: String) throws -> [Message2] {
        let data = try Data(contentsOf: Self.fixtureURL(filename))
        let text = String(decoding: data, as: UTF8.self)
        let resolver = Message2Resolver()
        var out: [Message2] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d),
                  let msg = try? resolver.resolve(json) else { continue }
            out.append(msg)
        }
        return out
    }

    private func feed(_ messages: [Message2], into handle: SessionHandle2, mode: SessionHandle2.ReceiveMode) {
        for m in messages { handle.receive(m, mode: mode) }
    }

    // MARK: - Live: real session end-to-end

    func testReceive_live_buildsTimelineFromRealSession() throws {
        let handle = makeHandle()
        let messages = try loadFixture("live-sample.jsonl")
        XCTAssertFalse(messages.isEmpty, "fixture yielded no messages")

        feed(messages, into: handle, mode: .live)

        XCTAssertFalse(handle.messages.isEmpty, "timeline empty after live ingest")
        XCTAssertLessThan(handle.messages.count, messages.count, "filter should drop non-user/assistant messages")
        XCTAssertNotNil(handle.cwd, "system.init should set cwd")
        XCTAssertGreaterThan(handle.contextWindowTokens, 0, "result.modelUsage should set context window")
        XCTAssertGreaterThan(handle.contextUsedTokens, 0, "assistant.usage should set used tokens")
        XCTAssertFalse(handle.slashCommands.isEmpty, "system.init should populate slashCommands")
    }

    func testReceive_live_mergesToolResultsInPlace() throws {
        let handle = makeHandle()
        feed(try loadFixture("live-sample.jsonl"), into: handle, mode: .live)

        let merged = handle.messages.reduce(0) { $0 + $1.toolResults.count }
        XCTAssertGreaterThan(merged, 0, "at least one assistant entry should have a tool_result merged")

        for entry in handle.messages where !entry.toolResults.isEmpty {
            guard case .assistant = entry.message else {
                XCTFail("toolResults attached to non-assistant entry"); return
            }
        }
    }

    // MARK: - Replay: Claude Code projects jsonl

    func testReceive_replay_buildsTimelineWithoutLifecycle() throws {
        let handle = makeHandle()
        let messages = try loadFixture("replay-sample.jsonl")
        XCTAssertFalse(messages.isEmpty)

        handle.status = .responding
        feed(messages, into: handle, mode: .replay)

        XCTAssertFalse(handle.messages.isEmpty)
        XCTAssertFalse(handle.hasUnread, "replay must not trigger hasUnread")
        guard case .responding = handle.status else {
            return XCTFail("replay must not advance lifecycle, got \(handle.status)")
        }
    }

    func testReceive_replay_mergesToolResults() throws {
        let handle = makeHandle()
        feed(try loadFixture("replay-sample.jsonl"), into: handle, mode: .replay)
        let merged = handle.messages.reduce(0) { $0 + $1.toolResults.count }
        XCTAssertGreaterThan(merged, 0)
    }

    // MARK: - Lifecycle branches

    func testReceive_live_advancesStartingToIdleOnInit() {
        let handle = makeHandle()
        handle.status = .starting
        handle.receive(makeSystemInit(cwd: "/tmp/foo"), mode: .live)

        XCTAssertEqual(handle.cwd, "/tmp/foo")
        guard case .idle = handle.status else {
            return XCTFail("expected .idle, got \(handle.status)")
        }
    }

    func testReceive_live_advancesRespondingToIdleOnResult() {
        let handle = makeHandle()
        handle.status = .responding
        handle.receive(makeResultSuccess(contextWindow: 200_000), mode: .live)

        XCTAssertEqual(handle.contextWindowTokens, 200_000)
        guard case .idle = handle.status else {
            return XCTFail("expected .idle, got \(handle.status)")
        }
    }

    func testReceive_live_leavesStatusAloneWhenNotActive() {
        let handle = makeHandle()
        handle.status = .notStarted
        handle.receive(makeResultSuccess(contextWindow: 1), mode: .live)
        guard case .notStarted = handle.status else {
            return XCTFail("result in .notStarted must not flip status")
        }
    }

    // MARK: - Presence

    func testReceive_live_setsHasUnreadWhenNotFocused() {
        let handle = makeHandle()
        handle.isFocused = false
        handle.receive(makeUserText("hello"), mode: .live)
        XCTAssertTrue(handle.hasUnread)
    }

    func testReceive_live_leavesHasUnreadClearWhenFocused() {
        let handle = makeHandle()
        handle.isFocused = true
        handle.receive(makeUserText("hello"), mode: .live)
        XCTAssertFalse(handle.hasUnread)
    }

    // MARK: - Filters

    func testReceive_skipsSyntheticUser() {
        let handle = makeHandle()
        handle.receive(makeUserText("visible"), mode: .live)
        handle.receive(makeUserText("hidden", synthetic: true), mode: .live)
        XCTAssertEqual(handle.messages.count, 1)
    }

    func testReceive_skipsSubagentUser() {
        let handle = makeHandle()
        handle.receive(makeUserText("sub", parentToolUseId: "toolu_abc"), mode: .live)
        XCTAssertTrue(handle.messages.isEmpty)
    }

    func testReceive_skipsEmptyUser() {
        let handle = makeHandle()
        handle.receive(makeUserText(""), mode: .live)
        XCTAssertTrue(handle.messages.isEmpty)
    }

    // MARK: - Message factories

    private func resolve(_ json: [String: Any]) -> Message2 {
        (try? Message2Resolver().resolve(json)) ?? .unknown(name: "factory-failed", raw: json)
    }

    private func makeSystemInit(cwd: String) -> Message2 {
        resolve([
            "type": "system",
            "subtype": "init",
            "cwd": cwd,
            "slash_commands": ["help", "clear"],
        ])
    }

    private func makeResultSuccess(contextWindow: Int) -> Message2 {
        resolve([
            "type": "result",
            "subtype": "success",
            "model_usage": [
                "claude-opus-4-7": ["context_window": contextWindow],
            ],
        ])
    }

    private func makeUserText(_ text: String, synthetic: Bool = false, parentToolUseId: String? = nil) -> Message2 {
        var json: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        if synthetic { json["is_synthetic"] = true }
        if let id = parentToolUseId { json["parent_tool_use_id"] = id }
        return resolve(json)
    }
}

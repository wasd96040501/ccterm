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

        let singles = handle.messages.flatMap(\.singles)
        let merged = singles.reduce(0) { $0 + $1.toolResults.count }
        XCTAssertGreaterThan(merged, 0, "at least one assistant single should have a tool_result merged")

        for single in singles where !single.toolResults.isEmpty {
            guard case .assistant = single.message else {
                XCTFail("toolResults attached to non-assistant single"); return
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
        let merged = handle.messages.flatMap(\.singles).reduce(0) { $0 + $1.toolResults.count }
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

    // MARK: - Grouping

    func testGrouping_firstGroupableMessage_opensGroupOfOne() {
        let handle = makeHandle()
        handle.receive(makeToolUse(name: "Read", id: "t1", input: ["file_path": "/x/a.swift"]), mode: .live)

        XCTAssertEqual(handle.messages.count, 1)
        guard case .group(let g) = handle.messages[0] else {
            return XCTFail("expected .group, got \(handle.messages[0])")
        }
        XCTAssertEqual(g.items.count, 1)
    }

    func testGrouping_adjacentGroupableAssistants_merge() {
        let handle = makeHandle()
        handle.receive(makeToolUse(name: "Read",  id: "t1", input: ["file_path": "/x/a.swift"]), mode: .live)
        handle.receive(makeToolUse(name: "Grep",  id: "t2", input: ["pattern": "foo"]),           mode: .live)
        handle.receive(makeToolUse(name: "Glob",  id: "t3", input: ["pattern": "**/*.ts"]),       mode: .live)
        handle.receive(makeToolUse(name: "Edit",  id: "t4", input: ["file_path": "/x/b.swift"]),  mode: .live)
        handle.receive(makeToolUse(name: "Bash",  id: "t5", input: ["command": "make", "description": "build"]), mode: .live)

        XCTAssertEqual(handle.messages.count, 1, "5 adjacent groupable assistants should collapse into 1 group")
        guard case .group(let g) = handle.messages[0] else { return XCTFail("expected .group") }
        XCTAssertEqual(g.items.count, 5)
    }

    func testGrouping_userBreaksGroup() {
        let handle = makeHandle()
        handle.receive(makeToolUse(name: "Read", id: "t1", input: ["file_path": "/x/a.swift"]), mode: .live)
        handle.receive(makeUserText("continue"), mode: .live)
        handle.receive(makeToolUse(name: "Read", id: "t2", input: ["file_path": "/x/b.swift"]), mode: .live)

        XCTAssertEqual(handle.messages.count, 3, "user text between two Reads must split into two groups + single")

        guard case .group(let g1) = handle.messages[0] else { return XCTFail("index 0 must be group") }
        XCTAssertEqual(g1.items.count, 1)
        guard case .single = handle.messages[1] else { return XCTFail("index 1 must be single user") }
        guard case .group(let g2) = handle.messages[2] else { return XCTFail("index 2 must be group") }
        XCTAssertEqual(g2.items.count, 1)
    }

    func testGrouping_nonGroupableToolDoesNotJoinGroup() {
        let handle = makeHandle()
        handle.receive(makeToolUse(name: "Read", id: "t1", input: ["file_path": "/x/a.swift"]), mode: .live)
        // TodoWrite is not on the whitelist → single, not appended to group.
        handle.receive(makeToolUse(name: "TodoWrite", id: "t2", input: ["todos": []]), mode: .live)
        handle.receive(makeToolUse(name: "Read", id: "t3", input: ["file_path": "/x/b.swift"]), mode: .live)

        XCTAssertEqual(handle.messages.count, 3)
        guard case .group = handle.messages[0] else { return XCTFail("first must be group") }
        guard case .single = handle.messages[1] else { return XCTFail("TodoWrite must be single") }
        guard case .group = handle.messages[2] else { return XCTFail("last must be fresh group") }
    }

    func testGrouping_assistantTextBreaksGroup() {
        let handle = makeHandle()
        handle.receive(makeToolUse(name: "Read", id: "t1", input: ["file_path": "/x/a.swift"]), mode: .live)
        handle.receive(makeAssistantText("thinking aloud"), mode: .live)
        handle.receive(makeToolUse(name: "Read", id: "t2", input: ["file_path": "/x/b.swift"]), mode: .live)

        XCTAssertEqual(handle.messages.count, 3)
        guard case .group(let g1) = handle.messages[0] else { return XCTFail() }
        XCTAssertEqual(g1.items.count, 1)
        guard case .single = handle.messages[1] else { return XCTFail("assistant text must be single") }
        guard case .group(let g2) = handle.messages[2] else { return XCTFail() }
        XCTAssertEqual(g2.items.count, 1)
    }

    func testGrouping_toolResultAttachesInsideGroup() {
        let handle = makeHandle()
        handle.receive(makeToolUse(name: "Read", id: "t1", input: ["file_path": "/x/a.swift"]), mode: .live)
        handle.receive(makeToolUse(name: "Grep", id: "t2", input: ["pattern": "foo"]),           mode: .live)
        handle.receive(makeToolResult(toolUseId: "t2", content: "matches"), mode: .live)

        guard case .group(let g) = handle.messages[0] else { return XCTFail("expected group") }
        XCTAssertEqual(g.items.count, 2)
        XCTAssertTrue(g.items[0].toolResults.isEmpty, "t1 should not have a result yet")
        XCTAssertEqual(g.items[1].toolResults["t2"]?.toolUseId, "t2", "t2 result must attach to its owning single")
    }

    // MARK: - Group title

    /// Title assertions compose expected values through the same `String(localized:)`
    /// path so they hold regardless of the runtime locale.

    func testTitle_active_showsLastItemProgressive() {
        var g = GroupEntry(id: UUID(), items: [])
        g.items.append(singleAssistant(makeToolUse(name: "Read", id: "t1", input: ["file_path": "/x/Alpha.swift"])))
        g.items.append(singleAssistant(makeToolUse(name: "Bash", id: "t2", input: ["command": "make", "description": "build project"])))

        let expected = String(localized: "Running: \("build project")")
        XCTAssertEqual(g.title(isActive: true), expected)
    }

    func testTitle_completed_bucketsByVerbCountFirstOccurrenceOrder() {
        var g = GroupEntry(id: UUID(), items: [])
        g.items.append(singleAssistant(makeToolUse(name: "Read",   id: "r1", input: ["file_path": "/x/a.swift"])))
        g.items.append(singleAssistant(makeToolUse(name: "Grep",   id: "s1", input: ["pattern": "foo"])))
        g.items.append(singleAssistant(makeToolUse(name: "Read",   id: "r2", input: ["file_path": "/x/b.swift"])))
        g.items.append(singleAssistant(makeToolUse(name: "Bash",   id: "b1", input: ["command": "ls", "description": "list"])))
        g.items.append(singleAssistant(makeToolUse(name: "Read",   id: "r3", input: ["file_path": "/x/c.swift"])))

        let expected = [
            String(localized: "Read \(3) files"),
            String(localized: "Searched \(1) patterns"),
            String(localized: "Ran \(1) commands"),
        ].joined(separator: " · ")
        XCTAssertEqual(g.title(isActive: false), expected)
    }

    func testTitle_completed_singleItemStillUsesCountForm() {
        var g = GroupEntry(id: UUID(), items: [])
        g.items.append(singleAssistant(makeToolUse(name: "Read", id: "r1", input: ["file_path": "/x/a.swift"])))
        XCTAssertEqual(g.title(isActive: false), String(localized: "Read \(1) files"))
    }

    // MARK: - Message factories

    private func singleAssistant(_ m: Message2) -> SingleEntry {
        SingleEntry(id: UUID(), message: m, delivery: nil, toolResults: [:])
    }

    private func makeToolUse(name: String, id: String, input: [String: Any]) -> Message2 {
        resolve([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input,
                ]],
            ],
        ])
    }

    private func makeAssistantText(_ text: String) -> Message2 {
        resolve([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    private func makeToolResult(toolUseId: String, content: String) -> Message2 {
        resolve([
            "type": "user",
            "message": [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": content,
                ]],
            ],
        ])
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

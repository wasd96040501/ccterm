import XCTest

@testable import AgentSDK

/// Transcript reconstruction over synthetic on-disk files that reproduce the
/// structures the CLI writes.
final class TranscriptTests: XCTestCase {
    // MARK: - Fixture builders

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func tick() -> JSONValue {
        clock += 1
        return .string(ISO8601.format(clock))
    }

    private func line(_ fields: [String: JSONValue]) -> String {
        String(decoding: try! JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self)
    }

    private func user(
        _ uuid: String, parent: String?, _ text: String, extra: [String: JSONValue] = [:]
    )
        -> String
    {
        var fields: [String: JSONValue] = [
            "type": "user", "uuid": .string(uuid), "parentUuid": parent.map(JSONValue.string) ?? .null,
            "sessionId": "s", "isSidechain": false, "timestamp": tick(), "cwd": "/repo", "gitBranch": "main",
            "message": ["role": "user", "content": .string(text)],
        ]
        fields.merge(extra) { $1 }
        return line(fields)
    }

    private func assistant(
        _ uuid: String, parent: String?, messageID: String, _ block: JSONValue, extra: [String: JSONValue] = [:]
    ) -> String {
        var fields: [String: JSONValue] = [
            "type": "assistant", "uuid": .string(uuid), "parentUuid": parent.map(JSONValue.string) ?? .null,
            "sessionId": "s", "isSidechain": false, "timestamp": tick(),
            "message": ["id": .string(messageID), "model": "m", "role": "assistant", "content": [block]],
        ]
        fields.merge(extra) { $1 }
        return line(fields)
    }

    private func text(_ s: String) -> JSONValue { ["type": "text", "text": .string(s)] }
    private func toolUse(_ id: String) -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": "Bash", "input": [:]]
    }

    private func toolResult(_ uuid: String, parent: String, toolUseID: String) -> String {
        line([
            "type": "user", "uuid": .string(uuid), "parentUuid": .string(parent), "sessionId": "s",
            "isSidechain": false, "timestamp": tick(), "sourceToolAssistantUUID": .string(parent),
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": .string(toolUseID), "content": "ok"]],
            ],
            "toolUseResult": ["stdout": "ok"],
        ])
    }

    private func transcript(_ lines: [String]) -> Transcript {
        Transcript(data: Data(lines.joined(separator: "\n").utf8))
    }

    private func uuids(_ t: Transcript) -> [String] {
        t.messages.compactMap { message in
            switch message {
            case .user(let m): return m.uuid
            case .assistant(let m): return m.uuid
            case .system(.compactBoundary): return "boundary"
            default: return nil
            }
        }
    }

    // MARK: - Tests

    func testLinearChainAndMetadata() {
        let lines = [
            line(["type": "queue-operation", "operation": "enqueue", "sessionId": "s"]),
            user("u1", parent: nil, "hello"),
            assistant("a1", parent: "u1", messageID: "m1", text("hi")),
            line(["type": "custom-title", "customTitle": "Named", "sessionId": "s"]),
            line(["type": "ai-title", "aiTitle": "Auto", "sessionId": "s"]),
            line(["type": "last-prompt", "lastPrompt": "hello", "leafUuid": "a1", "sessionId": "s"]),
        ]
        let result = transcript(lines)
        XCTAssertEqual(uuids(result), ["u1", "a1"])
        XCTAssertEqual(result.metadata.title, "Named")
        XCTAssertEqual(result.metadata.aiTitle, "Auto")
        XCTAssertEqual(result.metadata.lastPrompt, "hello")
        XCTAssertEqual(result.metadata.cwd, "/repo")
        XCTAssertEqual(result.metadata.gitBranch, "main")
        XCTAssertNotNil(result.metadata.createdAt)
        XCTAssertLessThan(result.metadata.createdAt!, result.metadata.updatedAt!)
        guard case .assistant(let a) = result.messages[1] else { return XCTFail() }
        XCTAssertEqual(a.content, [.text("hi")])
    }

    func testRepeatedUUIDKeepsFirstPositionAndLastContent() {
        let lines = [
            user("u1", parent: nil, "first"),
            assistant("a1", parent: "u1", messageID: "m1", text("old")),
            user("u2", parent: "a1", "second"),
            assistant("a1", parent: "u1", messageID: "m1", text("rewritten")),
        ]
        let result = transcript(lines)
        XCTAssertEqual(uuids(result), ["u1", "a1", "u2"])
        guard case .assistant(let a) = result.messages[1] else { return XCTFail() }
        XCTAssertEqual(a.content, [.text("rewritten")])
    }

    func testRewindFollowsLastPromptLeaf() {
        let base = [
            user("u1", parent: nil, "q"),
            assistant("a1", parent: "u1", messageID: "m1", text("x")),
            user("old", parent: "a1", "abandoned branch"),
            assistant("oldA", parent: "old", messageID: "m2", text("y")),
            user("new", parent: "a1", "edited prompt"),
        ]
        // The CLI records the rewound-to leaf; the newest row is on the other branch.
        let rewound = transcript(base + [line(["type": "last-prompt", "leafUuid": "oldA", "sessionId": "s"])])
        XCTAssertEqual(uuids(rewound), ["u1", "a1", "old", "oldA"])
        // A newer row that descends from the recorded leaf wins.
        let continued = transcript(base + [line(["type": "last-prompt", "leafUuid": "a1", "sessionId": "s"])])
        XCTAssertEqual(uuids(continued), ["u1", "a1", "new"])
        // No last-prompt: the newest branch.
        XCTAssertEqual(uuids(transcript(base)), ["u1", "a1", "new"])
        // Explicitly cleared.
        let cleared = transcript(
            base + [line(["type": "last-prompt", "leafUuid": nil, "explicit": true, "sessionId": "s"])])
        XCTAssertTrue(cleared.messages.isEmpty)
    }

    func testCompactionWithPreservedSegment() {
        let lines = [
            user("old1", parent: nil, "ancient"),
            assistant("head", parent: "old1", messageID: "m1", text("kept 1")),
            user("tail", parent: "head", "kept 2"),
            line([
                "type": "system", "subtype": "compact_boundary", "uuid": "b", "parentUuid": nil,
                "logicalParentUuid": "tail", "sessionId": "s", "timestamp": tick(),
                "compactMetadata": [
                    "trigger": "manual", "preTokens": 1000, "postTokens": 100,
                    "preservedSegment": ["headUuid": "head", "anchorUuid": "summary", "tailUuid": "tail"],
                ],
            ]),
            user(
                "summary", parent: "b", "This session is being continued…",
                extra: ["isCompactSummary": true, "isVisibleInTranscriptOnly": true]),
            user("after", parent: "tail", "next question"),
        ]
        let result = transcript(lines)
        XCTAssertEqual(uuids(result), ["boundary", "summary", "head", "tail", "after"])
        guard case .system(.compactBoundary(let boundary)) = result.messages[0],
            case .user(let summary) = result.messages[1]
        else { return XCTFail() }
        XCTAssertEqual(boundary, .init(trigger: "manual", preTokens: 1000, postTokens: 100))
        XCTAssertTrue(summary.isSynthetic)
    }

    func testFullCompactionStartsAtBoundary() {
        let lines = [
            user("old1", parent: nil, "ancient"),
            line([
                "type": "system", "subtype": "compact_boundary", "uuid": "b", "parentUuid": nil, "sessionId": "s",
                "timestamp": tick(), "compactMetadata": ["trigger": "auto", "preTokens": 5],
            ]),
            user("summary", parent: "b", "summary", extra: ["isCompactSummary": true]),
            user("after", parent: "summary", "go on"),
        ]
        XCTAssertEqual(uuids(transcript(lines)), ["boundary", "summary", "after"])
    }

    func testParallelToolCallsAreRecovered() {
        // One response with two tool calls: each block is a row, each result
        // hangs off the block that issued it, so t1's result and the second
        // block's sibling live off the walked path.
        let lines = [
            user("u", parent: nil, "run both"),
            assistant("A1", parent: "u", messageID: "m", toolUse("t1")),
            assistant("A2", parent: "A1", messageID: "m", toolUse("t2")),
            toolResult("R1", parent: "A1", toolUseID: "t1"),
            toolResult("R2", parent: "A2", toolUseID: "t2"),
            assistant("A3", parent: "R2", messageID: "m2", text("both done")),
        ]
        XCTAssertEqual(uuids(transcript(lines)), ["u", "A1", "A2", "R1", "R2", "A3"])
    }

    func testOffPathSiblingBlockIsRecovered() {
        let lines = [
            user("u", parent: nil, "go"),
            assistant("A1", parent: "u", messageID: "m", toolUse("t1")),
            assistant("A2", parent: "A1", messageID: "m", toolUse("t2")),
            toolResult("R2", parent: "A2", toolUseID: "t2"),
            // A sibling block written on a side branch, with its result.
            assistant("A3", parent: "A1", messageID: "m", toolUse("t3")),
            toolResult("R3", parent: "A3", toolUseID: "t3"),
            toolResult("R1", parent: "A1", toolUseID: "t1"),
            assistant("next", parent: "R2", messageID: "m2", text("done")),
        ]
        let result = uuids(transcript(lines))
        XCTAssertEqual(Set(result), ["u", "A1", "A2", "A3", "R1", "R2", "R3", "next"])
        XCTAssertEqual(result.first, "u")
        XCTAssertEqual(result.last, "next")
        XCTAssertLessThan(result.firstIndex(of: "A3")!, result.firstIndex(of: "R3")!)
    }

    func testProgressRowsAreCollapsed() {
        let lines = [
            user("u", parent: nil, "q"),
            line([
                "type": "progress", "uuid": "p", "parentUuid": "u", "sessionId": "s", "data": ["type": "bash_progress"],
            ]),
            assistant("a", parent: "p", messageID: "m", text("x")),
        ]
        XCTAssertEqual(uuids(transcript(lines)), ["u", "a"])
    }

    func testQueuedPromptBecomesUserMessage() {
        let lines = [
            user("u", parent: nil, "first"),
            line([
                "type": "attachment", "uuid": "q", "parentUuid": "u", "sessionId": "s", "timestamp": tick(),
                "attachment": ["type": "queued_command", "prompt": "also this", "commandMode": "prompt"],
            ]),
            assistant("a", parent: "q", messageID: "m", text("ok")),
        ]
        let result = transcript(lines)
        XCTAssertEqual(uuids(result), ["u", "q", "a"])
        guard case .user(let queued) = result.messages[1] else { return XCTFail() }
        XCTAssertEqual(queued.content, [.text("also this")])
        XCTAssertFalse(queued.isSynthetic)
    }

    func testMissingParentFallsBackToRecentRow() {
        let lines = [
            user("u", parent: nil, "q"),
            assistant("a", parent: "gone", messageID: "m", text("x")),
        ]
        XCTAssertEqual(uuids(transcript(lines)), ["u", "a"])
    }

    func testSidechainAndMalformedLinesAreSkipped() {
        let lines = [
            user("u", parent: nil, "q"),
            "{not json",
            "\0\0\0",
            user("side", parent: "u", "subagent prompt", extra: ["isSidechain": true]),
            assistant("a", parent: "u", messageID: "m", text("x")),
            #"{"type":"user","uuid":"torn","parentUuid":"a","mess"#,
        ]
        XCTAssertEqual(uuids(transcript(lines)), ["u", "a"])
        XCTAssertTrue(transcript([]).messages.isEmpty)
        XCTAssertTrue(transcript(["garbage"]).messages.isEmpty)
    }

    func testSubagentFileIsItsOwnThread() {
        let side: [String: JSONValue] = ["isSidechain": true, "agentId": "a1"]
        let lines = [
            user("u", parent: nil, "task", extra: side),
            assistant("a", parent: "u", messageID: "m", text("done"), extra: side),
        ]
        XCTAssertEqual(uuids(transcript(lines)), ["u", "a"])
    }

    func testMetadataReadsOnlyHeadAndTail() throws {
        let filler = String(repeating: "x", count: 1_000)
        var lines = [user("u1", parent: nil, "hello")]
        for index in 0..<200 {
            lines.append(assistant("a\(index)", parent: "u1", messageID: "m\(index)", text(filler)))
        }
        lines.append(line(["type": "ai-title", "aiTitle": "Auto", "sessionId": "s"]))
        lines.append(line(["type": "custom-title", "customTitle": "Named", "sessionId": "s"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(lines.joined(separator: "\n").utf8).write(to: url)

        let metadata = try SessionMetadata(contentsOf: url)
        XCTAssertEqual(metadata.title, "Named")
        XCTAssertEqual(metadata.cwd, "/repo")
        XCTAssertThrowsError(try SessionMetadata(contentsOf: url.appendingPathExtension("missing")))
    }
}

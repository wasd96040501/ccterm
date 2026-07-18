import XCTest

@testable import AgentSDK
@testable import ccterm

/// Pure-logic tests for the flat history transcript's row-building:
/// content-block-order splitting, adjacent-tool_use grouping into a single
/// group-header row, and user-message visibility. No window / no AppKit
/// mount — runs on the default suite + CI as a gate on the most bug-prone
/// code.
@MainActor
final class TranscriptRowBuilderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Markdown / user rows

    func testAssistantTextProducesMarkdownRow() {
        let rows = TranscriptRowBuilder.build(messages: [assistantText("Hello world")])
        XCTAssertEqual(rows.count, 1)
        guard case .block(let block) = rows[0].content else {
            return XCTFail("expected a block row")
        }
        guard case .paragraph = block.kind else { return XCTFail("expected paragraph") }
    }

    func testAssistantTextSplitsIntoMultipleRows() {
        let rows = TranscriptRowBuilder.build(
            messages: [assistantText("First para.\n\nSecond para.")])
        XCTAssertEqual(rows.count, 2, "each markdown block is its own row")
    }

    func testUserTextProducesBubble() {
        let rows = TranscriptRowBuilder.build(messages: [userText("thanks!")])
        XCTAssertEqual(rows.count, 1)
        guard case .block(let block) = rows[0].content, case .userBubble = block.kind else {
            return XCTFail("expected a user bubble")
        }
    }

    // MARK: - Grouping

    func testAdjacentToolUsesMergeIntoOneGroupHeader() {
        let rows = TranscriptRowBuilder.build(
            messages: [
                assistantTools([
                    ("Read", "t1", ["file_path": "/a.swift"]),
                    ("Grep", "t2", ["pattern": "foo"]),
                ])
            ])
        XCTAssertEqual(rows.count, 1, "adjacent tool_uses fold into one group-header row")
        guard case .groupHeader(let title) = rows[0].content else {
            return XCTFail("expected a group-header row")
        }
        // Two distinct tool kinds → two count phrases joined by " · "
        // (locale-independent separator; the phrases themselves are
        // localized so we don't assert their exact text).
        XCTAssertTrue(title.contains(" · "), "header joins per-kind count phrases: \(title)")
    }

    func testSingleToolStillFormsGroupHeader() {
        let rows = TranscriptRowBuilder.build(
            messages: [assistantTools([("Read", "t1", ["file_path": "/a.swift"])])])
        XCTAssertEqual(rows.count, 1)
        guard case .groupHeader(let title) = rows[0].content else {
            return XCTFail("a single tool_use is still a group header")
        }
        XCTAssertTrue(
            title.contains("a.swift"),
            "single tool uses its own completed fragment (basename): \(title)")
    }

    func testTextBetweenToolsSplitsGroups() {
        // One assistant message: [tool_use, text, tool_use] — the text
        // breaks adjacency, so the two tools do NOT merge.
        let msg = resolve([
            "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
            "message": [
                "id": "m", "type": "message", "role": "assistant",
                "content": [
                    [
                        "type": "tool_use", "id": "t1", "name": "Read",
                        "input": ["file_path": "/a.swift"],
                    ],
                    ["type": "text", "text": "between"],
                    [
                        "type": "tool_use", "id": "t2", "name": "Grep",
                        "input": ["pattern": "foo"],
                    ],
                ],
            ],
        ])
        let rows = TranscriptRowBuilder.build(messages: [msg])
        XCTAssertEqual(rows.count, 3, "group header, markdown, group header")
        guard case .groupHeader = rows[0].content else { return XCTFail("first group") }
        guard case .block = rows[1].content else { return XCTFail("middle markdown") }
        guard case .groupHeader = rows[2].content else { return XCTFail("second group") }
    }

    func testTwoIdenticalGroupsGetDistinctIds() {
        // Same tool kinds, two separate groups (split by text) — the ids
        // must not collide even though the aggregated titles match.
        let msg = resolve([
            "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
            "message": [
                "id": "m", "type": "message", "role": "assistant",
                "content": [
                    ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/a"]],
                    ["type": "text", "text": "x"],
                    ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "/b"]],
                ],
            ],
        ])
        let rows = TranscriptRowBuilder.build(messages: [msg])
        XCTAssertNotEqual(rows[0].id, rows[2].id, "distinct groups must get distinct ids")
    }

    // MARK: - Tool results produce no extra rows

    func testToolResultOnlyUserProducesNoRow() {
        let rows = TranscriptRowBuilder.build(
            messages: [userToolResult(toolUseId: "t1", content: "x")])
        XCTAssertTrue(rows.isEmpty, "a tool_result-only user message is not a bubble")
    }

    func testToolResultDoesNotAddBodyRow() {
        let rows = TranscriptRowBuilder.build(
            messages: [
                assistantTools([("Read", "t1", ["file_path": "/a.swift"])]),
                userToolResult(toolUseId: "t1", content: "1\tprint(1)"),
            ])
        XCTAssertEqual(rows.count, 1, "the tool body is not rendered — only the group header")
        guard case .groupHeader = rows[0].content else { return XCTFail("group header only") }
    }

    // MARK: - Visibility

    func testSyntheticUserFiltered() {
        let rows = TranscriptRowBuilder.build(
            messages: [userText("noise", synthetic: true)])
        XCTAssertTrue(rows.isEmpty)
    }

    func testTaskNotificationEnvelopeFiltered() {
        let rows = TranscriptRowBuilder.build(
            messages: [userText("<task-notification>done</task-notification>")])
        XCTAssertTrue(rows.isEmpty)
    }

    func testStableIdsAcrossRebuild() {
        let msgs = [
            assistantText("Hello"),
            assistantTools([("Read", "t1", ["file_path": "/a.swift"])]),
        ]
        let a = TranscriptRowBuilder.build(messages: msgs)
        let b = TranscriptRowBuilder.build(messages: msgs)
        XCTAssertEqual(a.map(\.id), b.map(\.id), "ids are deterministic across rebuilds")
    }

    // MARK: - Fixtures

    private func assistantText(_ text: String) -> Message2 {
        resolve([
            "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
            "message": [
                "id": "m", "type": "message", "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    private func assistantTools(_ tools: [(String, String, [String: Any])]) -> Message2 {
        let content = tools.map { tool -> [String: Any] in
            ["type": "tool_use", "id": tool.1, "name": tool.0, "input": tool.2]
        }
        return resolve([
            "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
            "message": [
                "id": "m", "type": "message", "role": "assistant", "content": content,
            ],
        ])
    }

    private func userText(_ text: String, synthetic: Bool = false) -> Message2 {
        var dict: [String: Any] = [
            "type": "user", "uuid": UUID().uuidString, "session_id": "s",
            "message": ["role": "user", "content": text],
        ]
        if synthetic { dict["is_synthetic"] = true }
        return resolve(dict)
    }

    private func userToolResult(toolUseId: String, content: String) -> Message2 {
        resolve([
            "type": "user", "uuid": UUID().uuidString, "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": toolUseId, "content": content]
                ],
            ],
        ])
    }

    private func resolve(_ dict: [String: Any]) -> Message2 {
        try! Message2Resolver().resolve(dict)
    }
}

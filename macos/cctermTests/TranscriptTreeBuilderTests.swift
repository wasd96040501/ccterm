import XCTest

@testable import AgentSDK
@testable import ccterm

/// Pure-logic tests for the outline transcript's tree-ification (SPEC §4):
/// content-block-order splitting, adjacent-tool_use grouping, tool
/// pairing, and user-message visibility. No window / no AppKit mount —
/// runs on the default suite + CI as a gate on the most bug-prone code.
@MainActor
final class TranscriptTreeBuilderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Markdown / user leaves

    func testAssistantTextProducesMarkdownRoot() {
        let roots = TranscriptTreeBuilder.build(messages: [assistantText("Hello world")])
        XCTAssertEqual(roots.count, 1)
        guard case .block(let block) = roots[0].content else {
            return XCTFail("expected a block node")
        }
        guard case .paragraph = block.kind else { return XCTFail("expected paragraph") }
        XCTAssertFalse(roots[0].isExpandable)
    }

    func testAssistantTextSplitsIntoMultipleTopNodes() {
        let roots = TranscriptTreeBuilder.build(
            messages: [assistantText("First para.\n\nSecond para.")])
        XCTAssertEqual(roots.count, 2, "each markdown block is its own top node")
    }

    func testUserTextProducesBubble() {
        let roots = TranscriptTreeBuilder.build(messages: [userText("thanks!")])
        XCTAssertEqual(roots.count, 1)
        guard case .block(let block) = roots[0].content, case .userBubble = block.kind else {
            return XCTFail("expected a user bubble")
        }
    }

    // MARK: - Grouping

    func testAdjacentToolUsesMergeIntoOneGroup() {
        let roots = TranscriptTreeBuilder.build(
            messages: [
                assistantTools([
                    ("Read", "t1", ["file_path": "/a.swift"]),
                    ("Grep", "t2", ["pattern": "foo"]),
                ])
            ])
        XCTAssertEqual(roots.count, 1, "adjacent tool_uses fold into one group")
        let group = roots[0]
        XCTAssertTrue(group.isExpandable)
        guard case .header = group.content else { return XCTFail("group header node") }
        XCTAssertEqual(group.children.count, 2, "two tool headers")
        for child in group.children {
            guard case .header = child.content else { return XCTFail("tool header node") }
        }
    }

    func testSingleToolStillFormsGroup() {
        let roots = TranscriptTreeBuilder.build(
            messages: [assistantTools([("Read", "t1", ["file_path": "/a.swift"])])])
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots[0].isExpandable, "a single tool_use is still a group")
        XCTAssertEqual(roots[0].children.count, 1)
    }

    func testTextBetweenToolsSplitsGroups() {
        // One assistant message: [tool_use, text, tool_use] — the text
        // breaks adjacency, so the two tools do NOT merge (§4 互不吞并).
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
        let roots = TranscriptTreeBuilder.build(messages: [msg])
        XCTAssertEqual(roots.count, 3, "group, markdown, group")
        XCTAssertTrue(roots[0].isExpandable)
        guard case .block = roots[1].content else { return XCTFail("middle markdown") }
        XCTAssertTrue(roots[2].isExpandable)
    }

    // MARK: - Tool pairing

    func testToolResultPairsIntoBody() {
        let roots = TranscriptTreeBuilder.build(
            messages: [
                assistantTools([("Read", "t1", ["file_path": "/a.swift"])]),
                userToolResult(toolUseId: "t1", content: "1\tprint(1)"),
            ])
        let toolHeader = roots[0].children[0]
        XCTAssertTrue(toolHeader.isExpandable, "read with content has a body")
        XCTAssertEqual(toolHeader.children.count, 1)
        guard case .toolBody = toolHeader.children[0].content else {
            return XCTFail("expected a tool body leaf")
        }
    }

    func testToolResultOnlyUserProducesNoBubble() {
        let roots = TranscriptTreeBuilder.build(
            messages: [userToolResult(toolUseId: "t1", content: "x")])
        XCTAssertTrue(roots.isEmpty, "a tool_result-only user message is not a bubble")
    }

    // MARK: - Visibility

    func testSyntheticUserFiltered() {
        let roots = TranscriptTreeBuilder.build(
            messages: [userText("noise", synthetic: true)])
        XCTAssertTrue(roots.isEmpty)
    }

    func testTaskNotificationEnvelopeFiltered() {
        let roots = TranscriptTreeBuilder.build(
            messages: [userText("<task-notification>done</task-notification>")])
        XCTAssertTrue(roots.isEmpty)
    }

    func testStableIdsAcrossRebuild() {
        let msgs = [
            assistantText("Hello"),
            assistantTools([("Read", "t1", ["file_path": "/a.swift"])]),
        ]
        let a = TranscriptTreeBuilder.build(messages: msgs)
        let b = TranscriptTreeBuilder.build(messages: msgs)
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

import XCTest

@testable import AgentSDK

/// Typed reads of tool inputs and outputs over shapes the CLI records.
final class ToolsTests: XCTestCase {
    private func result(_ toolUseResult: JSONValue?, isError: Bool = false, text: String = "ok") -> UserMessage {
        UserMessage(
            content: [.toolResult(ToolResultBlock(toolUseID: "t", content: [.text(text)], isError: isError))],
            toolUseResult: toolUseResult)
    }

    // MARK: - Inputs

    func testInputMatchesNameAndAliases() {
        let task = ToolUseBlock(id: "t", name: "Task", input: ["description": "Look", "prompt": "Find it"])
        XCTAssertEqual(task.input(as: Tools.Agent.self)?.prompt, "Find it")
        let agent = ToolUseBlock(id: "t", name: "Agent", input: ["prompt": "p", "run_in_background": true])
        XCTAssertEqual(agent.input(as: Tools.Agent.self)?.runInBackground, true)
        XCTAssertNil(agent.input(as: Tools.Bash.self))
        XCTAssertTrue(Tools.TaskStop.matches("KillShell"))
        XCTAssertFalse(Tools.TaskStop.matches("Bash"))
    }

    func testInputDecodingIsLenient() throws {
        let bash = ToolUseBlock(
            id: "t", name: "Bash",
            input: ["command": "ls", "timeout": "120000", "run_in_background": "true", "extra": [1, 2]])
        let input = try XCTUnwrap(bash.input(as: Tools.Bash.self))
        XCTAssertEqual(input.command, "ls")
        XCTAssertEqual(input.timeout, 120_000)
        XCTAssertTrue(input.runInBackground)
        XCTAssertFalse(input.dangerouslyDisableSandbox)

        let read = ToolUseBlock(id: "t", name: "Read", input: ["file_path": "/a", "offset": 10.0, "limit": true])
        XCTAssertEqual(read.input(as: Tools.Read.self)?.offset, 10)
        XCTAssertNil(read.input(as: Tools.Read.self)?.limit)

        // A missing required field fails the whole input.
        XCTAssertNil(ToolUseBlock(id: "t", name: "Bash", input: [:]).input(as: Tools.Bash.self))
        XCTAssertNil(ToolUseBlock(id: "t", name: "Bash", input: "ls").input(as: Tools.Bash.self))
    }

    func testTodoDefaults() {
        let block = ToolUseBlock(
            id: "t", name: "TodoWrite",
            input: ["todos": [["content": "Ship", "status": "in_progress"], ["content": "Test", "status": "weird"]]])
        let todos = block.input(as: Tools.TodoWrite.self)?.todos
        XCTAssertEqual(todos?.map(\.status), [.inProgress, .pending])
        XCTAssertEqual(todos?.first?.activeForm, "Ship")
    }

    // MARK: - Outcomes

    func testOutcomeSuccessFailureAndUnavailable() {
        guard
            case .success(let output)? = result(["stdout": "hi", "stderr": "", "interrupted": false])
                .toolOutcome(Tools.Bash.self)
        else { return XCTFail("expected success") }
        XCTAssertEqual(output.stdout, "hi")

        XCTAssertEqual(
            result(["stdout": ""], isError: true, text: "Exit code 1").toolOutcome(Tools.Bash.self),
            .failure("Exit code 1"))
        // Errors recorded as a bare string.
        XCTAssertEqual(result("Error: denied").toolOutcome(Tools.Bash.self), .failure("Error: denied"))
        // No structured output (e.g. a streamed message).
        XCTAssertEqual(result(nil).toolOutcome(Tools.Bash.self), .unavailable)
        // Not a tool result at all.
        XCTAssertNil(UserMessage(content: [.text("hi")]).toolOutcome(Tools.Bash.self))
    }

    func testReadOutputs() {
        let text: JSONValue = [
            "type": "text",
            "file": ["filePath": "/a.swift", "content": "let x = 1", "numLines": 1, "startLine": 3, "totalLines": 9],
        ]
        guard case .success(.text(let file))? = result(text).toolOutcome(Tools.Read.self) else { return XCTFail() }
        XCTAssertEqual(file.filePath, "/a.swift")
        XCTAssertEqual(file.startLine, 3)
        XCTAssertEqual(file.totalLines, 9)

        let image: JSONValue = ["type": "image", "file": ["base64": "AAAA", "type": "image/png"]]
        XCTAssertEqual(
            result(image).toolOutcome(Tools.Read.self), .success(.image(base64: "AAAA", mediaType: "image/png")))
        let unchanged: JSONValue = ["type": "file_unchanged", "file": ["filePath": "/a"]]
        XCTAssertEqual(result(unchanged).toolOutcome(Tools.Read.self), .success(.unchanged(filePath: "/a")))
        let future: JSONValue = ["type": "hologram", "file": [:]]
        XCTAssertEqual(result(future).toolOutcome(Tools.Read.self), .success(.other(future)))
    }

    func testAgentOutputs() {
        let completed: JSONValue = [
            "status": "completed", "agentId": "a1", "totalToolUseCount": 4, "totalDurationMs": 1500,
            "totalTokens": 900, "content": [["type": "text", "text": "Found"], ["type": "text", "text": "it"]],
        ]
        guard case .success(.completed(let run))? = result(completed).toolOutcome(Tools.Agent.self) else {
            return XCTFail()
        }
        XCTAssertEqual(run.agentID, "a1")
        XCTAssertEqual(run.text, "Found\nit")
        XCTAssertEqual(run.totalToolUseCount, 4)

        let launched: JSONValue = ["status": "async_launched", "agentId": "a2", "outputFile": "/tmp/a2"]
        XCTAssertEqual(
            result(launched).toolOutcome(Tools.Agent.self), .success(.launched(agentID: "a2", outputFile: "/tmp/a2")))
    }

    func testWebSearchOutput() {
        let output: JSONValue = [
            "query": "swift", "durationSeconds": 1.5,
            "results": [
                [
                    "tool_use_id": "s",
                    "content": [["title": "Swift.org", "url": "https://swift.org"], ["url": "https://x"]],
                ],
                "Swift is a language.",
            ],
        ]
        guard case .success(let search)? = result(output).toolOutcome(Tools.WebSearch.self) else { return XCTFail() }
        XCTAssertEqual(search.links.map(\.title), ["Swift.org", "https://x"])
        XCTAssertEqual(search.summaries, ["Swift is a language."])
        XCTAssertEqual(search.durationSeconds, 1.5)
    }
}

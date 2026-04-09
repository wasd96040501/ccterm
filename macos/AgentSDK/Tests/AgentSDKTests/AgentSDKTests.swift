import Foundation
import Testing

@testable import AgentSDK

// MARK: - @JSON alt: key tests

@Test func userMessage_camelCaseKey_parsesToolUseResult() async throws {
    // History JSONL format: camelCase envelope keys
    let json: [String: Any] = [
        "type": "user",
        "message": ["role": "user", "content": "hello"],
        "toolUseResult": ["stdout": "output", "stderr": "", "interrupted": false],
        "sessionId": "sess-1",
        "sourceToolUseID": "toolu_123",
    ]
    let msg = try UserMessage(json: json)
    let result = msg.toolUseResultCamel as? [String: Any]
    #expect(result != nil)
    #expect(result?["stdout"] as? String == "output")
    #expect(msg.sessionId == "sess-1")
    #expect(msg.sourceToolUseId == "toolu_123")
}

@Test func userMessage_snakeCaseKey_parsesToolUseResult() async throws {
    // Live stream format: snake_case envelope keys
    let json: [String: Any] = [
        "type": "user",
        "message": ["role": "user", "content": "hello"],
        "tool_use_result": ["stdout": "live output", "stderr": "", "interrupted": false],
        "session_id": "sess-2",
        "source_tool_use_id": "toolu_456",
    ]
    let msg = try UserMessage(json: json)
    let result = msg.toolUseResultCamel as? [String: Any]
    #expect(result != nil)
    #expect(result?["stdout"] as? String == "live output")
    #expect(msg.sessionId == "sess-2")
    #expect(msg.sourceToolUseId == "toolu_456")
}

@Test func userMessage_camelTakesPrecedenceOverSnake() async throws {
    // When both keys present, camelCase (primary) wins
    let json: [String: Any] = [
        "type": "user",
        "message": ["role": "user", "content": "hello"],
        "toolUseResult": ["stdout": "camel wins"],
        "tool_use_result": ["stdout": "snake loses"],
        "sessionId": "camel-session",
        "session_id": "snake-session",
    ]
    let msg = try UserMessage(json: json)
    let result = msg.toolUseResultCamel as? [String: Any]
    #expect(result?["stdout"] as? String == "camel wins")
    #expect(msg.sessionId == "camel-session")
}

@Test func assistantMessage_snakeCaseEnvelope() async throws {
    let json: [String: Any] = [
        "type": "assistant",
        "message": [
            "content": [] as [Any],
            "model": "claude-opus-4-20250514",
            "stop_reason": NSNull(),
            "stop_sequence": NSNull(),
        ],
        "session_id": "sess-live",
        "parent_uuid": NSNull(),
        "is_sidechain": false,
    ]
    let msg = try AssistantMessage(json: json)
    #expect(msg.sessionId == "sess-live")
    #expect(msg.isSidechain == false)
}

@Test func progressMessage_snakeCaseKeys() async throws {
    let json: [String: Any] = [
        "type": "progress",
        "data": ["key": "value"],
        "parent_tool_use_id": "parent_123",
        "tool_use_id": "tool_456",
        "session_id": "sess-prog",
    ]
    let msg = try ProgressMessage(json: json)
    #expect(msg.parentToolUseId == "parent_123")
    #expect(msg.toolUseId == "tool_456")
    #expect(msg.sessionId == "sess-prog")
}

@Test func progressMessage_camelCaseKeys() async throws {
    let json: [String: Any] = [
        "type": "progress",
        "data": ["key": "value"],
        "parentToolUseID": "parent_789",
        "toolUseID": "tool_012",
        "sessionId": "sess-hist",
    ]
    let msg = try ProgressMessage(json: json)
    #expect(msg.parentToolUseId == "parent_789")
    #expect(msg.toolUseId == "tool_012")
    #expect(msg.sessionId == "sess-hist")
}

@Test func systemMessage_snakeCaseKeys() async throws {
    let json: [String: Any] = [
        "subtype": "api_retry",
        "duration_ms": 1500,
        "retry_in_ms": 2000.0,
        "retry_attempt": 1,
        "max_retries": 3,
        "session_id": "sess-sys",
        "is_meta": true,
    ]
    let msg = try SystemMessage(json: json)
    #expect(msg.durationMs == 1500)
    #expect(msg.retryInMs == 2000.0)
    #expect(msg.retryAttempt == 1)
    #expect(msg.maxRetries == 3)
    #expect(msg.sessionId == "sess-sys")
    #expect(msg.isMeta == true)
}

@Test func bashToolResult_snakeCaseKeys() async throws {
    let json: [String: Any] = [
        "stdout": "hello",
        "stderr": "",
        "interrupted": false,
        "is_image": false,
        "no_output_expected": true,
    ]
    let result = try BashToolResult(json: json)
    #expect(result.isImage == false)
    #expect(result.noOutputExpected == true)
}

@Test func bashToolResult_camelCaseKeys() async throws {
    let json: [String: Any] = [
        "stdout": "hello",
        "stderr": "",
        "interrupted": false,
        "isImage": true,
        "noOutputExpected": false,
    ]
    let result = try BashToolResult(json: json)
    #expect(result.isImage == true)
    #expect(result.noOutputExpected == false)
}

@Test func editToolResult_snakeCaseKeys() async throws {
    let json: [String: Any] = [
        "file_path": "/tmp/test.swift",
        "old_string": "foo",
        "new_string": "bar",
        "structured_patch": [] as [Any],
    ]
    let result = try EditToolResult(json: json)
    #expect(result.filePath == "/tmp/test.swift")
    #expect(result.oldString == "foo")
    #expect(result.newString == "bar")
}

@Test func toJSON_usesPrimaryKey() async throws {
    // Verify toJSON still outputs camelCase (primary key), not snake_case alt
    let json: [String: Any] = [
        "subtype": "test",
        "duration_ms": 100,
        "session_id": "s1",
    ]
    let msg = try SystemMessage(json: json)
    let output = msg.toJSON()
    // Primary keys should be used in output
    #expect(output["durationMs"] != nil)
    #expect(output["sessionId"] != nil)
    // snake_case alt should NOT appear in output
    #expect(output["duration_ms"] == nil)
    #expect(output["session_id"] == nil)
}

@Test func rateLimitInfo_snakeCaseKeys() async throws {
    let json: [String: Any] = [
        "status": "allowed",
        "resets_at": 1_234_567_890,
        "rate_limit_type": "five_hour",
        "overage_status": "rejected",
    ]
    let info = try RateLimitInfo2(json: json)
    #expect(info.resetsAt == 1_234_567_890)
    #expect(info.rateLimitType == "five_hour")
    #expect(info.overageStatus == "rejected")
}

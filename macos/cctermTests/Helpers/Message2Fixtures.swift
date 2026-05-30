import AgentSDK
import Foundation

@testable import ccterm

/// JSON-driven Message2 fixtures for unit tests. We construct messages by
/// feeding JSON dictionaries through `Message2Resolver` (the same path
/// production code uses for JSONL replay), avoiding hand-built generated
/// types whose initializers shift between SDK regenerations.
enum Message2Fixtures {

    /// One assistant text message. `parentToolUseId == nil` so it counts
    /// as visible.
    static func assistantText(_ text: String, messageId: String = "m") -> Message2 {
        resolve([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
            ],
        ])
    }

    /// One assistant text message carrying a `usage` block — for turn-token
    /// reconciliation tests. `inputTokens` is the fresh (non-cache) input.
    static func assistantWithUsage(
        messageId: String,
        text: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> Message2 {
        resolve([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": text]],
                "usage": [
                    "input_tokens": inputTokens,
                    "output_tokens": outputTokens,
                ],
            ],
        ])
    }

    /// One user message containing a plain text content array. `uuid` is
    /// settable so tests can pretend the CLI is echoing back a specific
    /// `SingleEntry.id`.
    static func userText(_ text: String, uuid: String = UUID().uuidString) -> Message2 {
        resolve([
            "type": "user",
            "uuid": uuid,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    /// A `Message2.system(.init)` — the CLI's session bootstrap /
    /// turn-prologue blob. Emitted once at attach-time and again at
    /// the start of every CLI-spawned follow-up turn (see
    /// `AgentSDKMessageDumpSmokeTests`).
    static func systemInit(
        sessionId: String = "s",
        permissionMode: String = "default",
        slashCommands: [String]? = nil
    ) -> Message2 {
        var dict: [String: Any] = [
            "type": "system",
            "subtype": "init",
            "uuid": UUID().uuidString,
            "session_id": sessionId,
            "cwd": "/tmp",
            "permissionMode": permissionMode,
        ]
        // The CLI's `system.init` carries command names only (no
        // descriptions) — mirror that wire shape so the merge-on-adopt
        // path is exercised faithfully.
        if let slashCommands { dict["slash_commands"] = slashCommands }
        return resolve(dict)
    }

    /// A `Message2.system(.status)` — CLI's broadcast for session-side
    /// state changes (today: `permissionMode`). Triggered whenever the
    /// CLI flips its `toolPermissionContext.mode`: EnterPlanMode runs,
    /// a permission_request is answered with a `setMode` suggestion,
    /// or the CLI silently corrects a requested mode it cannot honour.
    /// PermissionModeProbe captures all three forms.
    static func systemStatus(
        permissionMode: String, sessionId: String = "s"
    ) -> Message2 {
        resolve([
            "type": "system",
            "subtype": "status",
            "uuid": UUID().uuidString,
            "session_id": sessionId,
            "permissionMode": permissionMode,
        ])
    }

    /// A `Message2.result` (turn-end) message. The default branch is
    /// `success`; pass `subtype: "error_during_execution"` for the
    /// error branch. The CLI emits exactly one of these per turn at
    /// turn close — see `AgentSDKMessageDumpSmokeTests` for raw samples.
    static func result(subtype: String = "success", sessionId: String = "s") -> Message2 {
        resolve([
            "type": "result",
            "uuid": UUID().uuidString,
            "session_id": sessionId,
            "subtype": subtype,
            "duration_ms": 100,
            "duration_api_ms": 80,
            "is_error": false,
            "num_turns": 1,
            "result": "ok",
        ])
    }

    /// A `Message2.system(.thinkingTokens)` — the CLI's redacted-thinking
    /// progress signal. `estimatedTokens` is the cumulative (conservative)
    /// thinking-token estimate for the current block; `estimatedTokensDelta`
    /// is the per-frame increment. See `ThinkingUsageSmoke` for live samples.
    static func systemThinkingTokens(
        estimatedTokens: Int, estimatedTokensDelta: Int, sessionId: String = "s"
    ) -> Message2 {
        resolve([
            "type": "system",
            "subtype": "thinking_tokens",
            "uuid": UUID().uuidString,
            "session_id": sessionId,
            "estimated_tokens": estimatedTokens,
            "estimated_tokens_delta": estimatedTokensDelta,
        ])
    }

    /// Assistant message containing exactly one Read tool_use block. Useful
    /// for tool_group rendering tests.
    static func assistantRead(
        toolUseId: String, filePath: String
    ) -> Message2 {
        resolve([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m",
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "Read",
                        "input": ["file_path": filePath],
                    ]
                ],
            ],
        ])
    }

    /// A user message carrying a single `tool_result` block (the CLI's
    /// envelope for a tool's output). Pairs with `assistantRead(...)` /
    /// any tool_use of the same `toolUseId`.
    static func userToolResult(
        toolUseId: String, text: String = "ok", isError: Bool = false
    ) -> Message2 {
        resolve([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": text,
                        "is_error": isError,
                    ]
                ],
            ],
        ])
    }

    /// JSONL line for `assistantText(...)` — useful when a test feeds bytes
    /// into `SessionRuntime.loadHistory(overrideURL:)`.
    static func assistantTextJSONL(_ text: String) -> String {
        jsonl([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m\(UUID().uuidString.prefix(8))",
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    static func userTextJSONL(_ text: String) -> String {
        jsonl([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    /// JSONL line for a groupable assistant tool_use (one Read block) — a
    /// "tool child" for merge-aware first-page counting.
    static func assistantReadJSONL(toolUseId: String, filePath: String) -> String {
        jsonl([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m\(UUID().uuidString.prefix(8))",
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "Read",
                        "input": ["file_path": filePath],
                    ]
                ],
            ],
        ])
    }

    /// JSONL line for a user `tool_result` envelope — a "tool child" that pairs
    /// with `assistantReadJSONL(toolUseId:)`.
    static func userToolResultJSONL(
        toolUseId: String, text: String = "ok", isError: Bool = false
    ) -> String {
        jsonl([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": text,
                        "is_error": isError,
                    ]
                ],
            ],
        ])
    }

    // MARK: - Stream events (partial messages)

    /// `message_start` SSE sub-event. `inputTokens` / `outputTokens` seed the
    /// initial usage block the CLI sends up front.
    static func streamMessageStart(
        messageId: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) -> Message2StreamEvent {
        var usage: [String: Any] = [:]
        if let inputTokens { usage["input_tokens"] = inputTokens }
        if let outputTokens { usage["output_tokens"] = outputTokens }
        var message: [String: Any] = ["id": messageId, "role": "assistant", "type": "message"]
        if !usage.isEmpty { message["usage"] = usage }
        return streamEvent(["type": "message_start", "message": message])
    }

    /// `content_block_delta` carrying a `text_delta`.
    static func streamTextDelta(index: Int, text: String) -> Message2StreamEvent {
        streamEvent([
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "text_delta", "text": text],
        ])
    }

    /// `content_block_delta` carrying a `thinking_delta` (ignored for text by
    /// the assembler — used to prove it's skipped).
    static func streamThinkingDelta(index: Int, thinking: String) -> Message2StreamEvent {
        streamEvent([
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "thinking_delta", "thinking": thinking],
        ])
    }

    /// `content_block_delta` carrying an `input_json_delta` (tool-use args;
    /// ignored by the assembler).
    static func streamInputJSONDelta(index: Int, partialJSON: String) -> Message2StreamEvent {
        streamEvent([
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "input_json_delta", "partial_json": partialJSON],
        ])
    }

    /// `message_delta` carrying a cumulative output-token count.
    static func streamMessageDelta(outputTokens: Int) -> Message2StreamEvent {
        streamEvent([
            "type": "message_delta",
            "delta": [:],
            "usage": ["output_tokens": outputTokens],
        ])
    }

    private static func streamEvent(_ event: [String: Any]) -> Message2StreamEvent {
        do {
            return try Message2StreamEvent(json: [
                "type": "stream_event",
                "uuid": UUID().uuidString,
                "session_id": "s",
                "event": event,
            ])
        } catch {
            fatalError("Message2Fixtures: stream event parse failed: \(error)\n\(event)")
        }
    }

    // MARK: - Internals

    private static func resolve(_ dict: [String: Any]) -> Message2 {
        do {
            return try Message2Resolver().resolve(dict)
        } catch {
            fatalError("Message2Fixtures: resolver failed: \(error)\n\(dict)")
        }
    }

    private static func jsonl(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8)!
    }
}

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
    static func systemInit(sessionId: String = "s", permissionMode: String = "default") -> Message2 {
        resolve([
            "type": "system",
            "subtype": "init",
            "uuid": UUID().uuidString,
            "session_id": sessionId,
            "cwd": "/tmp",
            "permissionMode": permissionMode,
        ])
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

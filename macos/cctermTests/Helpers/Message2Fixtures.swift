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

    /// One user message containing a plain text content array.
    static func userText(_ text: String) -> Message2 {
        resolve([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
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

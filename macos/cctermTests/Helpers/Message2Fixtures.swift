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

    /// One assistant `tool_use` JSONL line. `toolUseId` is the anchor a
    /// matching `tool_result` user line refers back to.
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

    /// One user `tool_result` JSONL line that resolves a prior tool_use.
    static func userToolResultJSONL(toolUseId: String, content: String) -> String {
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
                        "content": content,
                    ]
                ],
            ],
        ])
    }

    /// Synthesise `n` mixed JSONL lines for a non-trivial history fixture:
    /// alternating user prompts, assistant prose, and (every fifth turn)
    /// a Read tool_use + matching tool_result. Output is plain English;
    /// the goal is "exceeds one viewport and trips the Phase A → Phase B
    /// boundary", not realism beyond what the renderer parses.
    static func bulkAssortedJSONL(count n: Int) -> [String] {
        precondition(n > 0)
        let userPrompts = [
            "Walk me through the chat transcript layout pipeline.",
            "Where does the bridge translate MessagesChange events?",
            "How is the loading pill rendered in the transcript?",
            "Explain the two-phase history load.",
            "Why does setHistory replace the block list?",
            "How does anchor-on-mount work after the refactor?",
            "Can you summarize the coordinator's responsibilities?",
            "What happens when the user switches sessions in the sidebar?",
        ]
        let assistantParagraphs = [
            "The transcript is an `NSTableView` driven by a coordinator. Blocks "
                + "are diffed and rows are noted for height; nothing flows through "
                + "SwiftUI's normal layout path.",
            "Each `MessagesChange` event is consumed by the bridge, which maps "
                + "entries into block ids and forwards `apply` calls. The "
                + "controller is the public surface; the coordinator owns the table.",
            "The pill row is a sentinel block appended at the tail when "
                + "`isRunning` flips true. Removing it is the bridge's job once the "
                + "session quiets down again.",
            "Phase A reads the byte tail of the JSONL, parses ~80 lines forward, "
                + "and emits `.reset` with precomputed blocks. Phase B reads the "
                + "remaining prefix off-main and prepends it.",
            "Calling `setHistory` is the same as calling `loadInitial` used to "
                + "be — it replaces the contents and re-anchors. Every call resets "
                + "`isAnchorSettled` until the next layout pass settles.",
        ]
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let turn = i / 2
            if i.isMultiple(of: 2) {
                let prompt = userPrompts[turn % userPrompts.count]
                out.append(userTextJSONL("Turn \(turn + 1): \(prompt)"))
            } else if turn.isMultiple(of: 5), turn > 0 {
                let useId = "toolu_bulk_\(turn)"
                out.append(
                    assistantReadJSONL(
                        toolUseId: useId,
                        filePath: "/tmp/transcript-fixture/turn-\(turn).md"))
                if out.count < n {
                    out.append(
                        userToolResultJSONL(
                            toolUseId: useId,
                            content: "Read 42 lines from turn-\(turn).md."))
                }
            } else {
                let p = assistantParagraphs[turn % assistantParagraphs.count]
                out.append(assistantTextJSONL("Turn \(turn + 1) reply — \(p)"))
            }
        }
        return Array(out.prefix(n))
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

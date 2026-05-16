#if DEBUG

import Foundation

/// Seeds the transcript with a Bash tool call whose stdout text is
/// searchable, followed by a plain assistant message that also matches.
/// Two roles, one fixture:
///
/// - The Bash tool group exercises `ToolGroupLayout.searchableRegions`
///   when the user expands the group + child (the new code path added
///   alongside this scenario).
/// - The trailing assistant text gives the search-bar smoke test
///   something to land on without requiring chevron interaction —
///   tool groups default to folded, and clicking a self-drawn chevron
///   from XCUITest needs coordinate hacks.
///
/// stdout is intentionally multi-line so the UTF-16 newline accounting
/// in `searchableRegions` (U+2028 → `\n` normalisation on the section
/// side, and char offsets that match `.textCard(...)` positions) gets
/// exercised under live layout, not just unit-test fixtures.
final class ToolGroupSearchableContentScenario: MockCLIBaseScenario {

    override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
        if let uuid {
            send.echoUser(text: text, uuid: uuid, sessionId: sessionId)
        }
        let toolUseId = "tooluse-" + UUID().uuidString.prefix(8)
        let messageId = UUID().uuidString
        send.sendJSON([
            "type": "assistant",
            "session_id": sessionId,
            "uuid": UUID().uuidString,
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "Bash",
                        "input": [
                            "command": "echo apple",
                            "description": "echo a fruit",
                        ] as [String: Any],
                    ]
                ],
            ] as [String: Any],
        ])
        send.sendJSON([
            "type": "user",
            "session_id": sessionId,
            "uuid": UUID().uuidString,
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": "apple banana\ncherry apple\nbanana cherry",
                        "is_error": false,
                    ] as [String: Any]
                ],
            ] as [String: Any],
            "tool_use_result": [
                "stdout": "apple banana\ncherry apple\nbanana cherry",
                "stderr": "",
                "interrupted": false,
                "is_image": false,
            ] as [String: Any],
        ])
        // Trailing plain text so the smoke search has at least one
        // top-level hit to navigate to without unfolding the tool group.
        send.sendAssistantText(
            "summary: ran echo apple, output had apple twice",
            sessionId: sessionId)
        send.sendResultSuccess(sessionId: sessionId)
    }
}

#endif

import AgentSDK
import Foundation

/// A pending permission request from the CLI awaiting decision. Holds the
/// request content and a response closure. The UI shows the request, and
/// once the user decides, calling `respond` sends the decision back to the
/// CLI and removes the entry from the list.
struct PendingPermission: Identifiable {
    let id: String
    let request: PermissionRequest
    /// Reply to the CLI. The closure removes the entry from
    /// pendingPermissions on its own.
    let respond: (PermissionDecision) -> Void
}

/// A slash command advertised by the CLI during initialize.
struct SlashCommand {
    let name: String
    let description: String?
}

/// Normalize a user message into a single-line sidebar title:
/// collapse newlines into spaces, trim surrounding whitespace, and
/// truncate to `maxLength` characters (appending `…` when cut). Result
/// may be empty when the input is whitespace-only — callers should
/// guard against that.
///
/// Used by `Session.send(text:)` during draft → runtime promotion to
/// seed `runtime.title` before the first persist, and as a pure helper
/// for tests that want to assert on the derivation.
func deriveTitleFromFirstMessage(_ text: String, maxLength: Int = 80) -> String {
    let oneLine =
        text
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
    if trimmed.count > maxLength {
        return trimmed.prefix(maxLength) + "…"
    }
    return trimmed
}

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

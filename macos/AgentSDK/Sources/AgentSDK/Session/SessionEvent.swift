import Foundation

/// Everything a ``Session`` reports, in the order the CLI produced it.
public enum SessionEvent: Sendable {
    case message(Message)
    /// A tool call needs approval; answer with ``PermissionRequest/respond(_:)``.
    case permissionRequest(PermissionRequest)
    /// The CLI withdrew the request with this ``PermissionRequest/id``;
    /// dismiss any UI showing it.
    case permissionRequestCancelled(id: String)
    /// A slash command typed in the session (`/effort`, `/fast`) changed a
    /// flag setting: the shallow-merge patch the CLI applied (its
    /// `apply_flag_settings` sent to the host). A change the host made itself
    /// with ``Session/applySettings(_:)`` is not echoed.
    case flagSettingsChanged(JSONValue)
    /// The CLI process ended. Always the last event; the stream finishes
    /// right after it.
    case exited(Termination)
}

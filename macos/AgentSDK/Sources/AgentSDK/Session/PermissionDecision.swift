import Foundation

/// The answer to a ``PermissionRequest``.
public enum PermissionDecision: Sendable, Equatable {
    /// Run the tool.
    ///
    /// - Parameters:
    ///   - updatedInput: Replaces the tool's input (for example, the user's
    ///     answers to `AskUserQuestion`); `nil` runs it with the original input.
    ///   - updatedPermissions: Rule or mode changes to apply, typically picked
    ///     from ``PermissionRequest/suggestions``.
    case allow(updatedInput: JSONValue? = nil, updatedPermissions: [PermissionUpdate] = [])
    /// Refuse the tool call.
    ///
    /// - Parameters:
    ///   - message: Shown to the model as the reason.
    ///   - interrupt: Also end the turn instead of letting the model continue.
    case deny(message: String, interrupt: Bool = false)
}

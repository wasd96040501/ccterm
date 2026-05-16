import Foundation

/// Decision returned for a permission request.
public enum PermissionDecision {
    /// Allow this tool call, optionally with an edited input.
    case allow(updatedInput: [String: Any]? = nil)
    /// Allow and remember the rule (applies `permissionSuggestions` by default), with optional input and custom permission updates.
    case allowAlways(updatedInput: [String: Any]? = nil, updatedPermissions: [[String: Any]]? = nil)
    /// Deny this tool call with a reason. `interrupt: true` aborts the current execution.
    case deny(reason: String = "", interrupt: Bool = false)
}

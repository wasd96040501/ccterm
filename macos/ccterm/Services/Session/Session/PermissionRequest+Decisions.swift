import AgentSDK
import Foundation

/// The decisions the permission card's buttons produce, worded the way the
/// CLI's own terminal UI words them so the model sees the same reasons.
extension PermissionRequest {
    private static let toolVerbs: [String: String] = [
        "Bash": "running", "Read": "reading", "Write": "writing to",
        "Edit": "editing", "Glob": "searching", "Grep": "searching",
        "Task": "running task", "ExitPlanMode": "the plan",
    ]

    private static let feedbackTemplate =
        "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n"

    /// Allow this call, optionally with a user-edited input.
    func allowOnce(updatedInput: JSONValue? = nil) -> PermissionDecision {
        .allow(updatedInput: updatedInput)
    }

    /// Allow and remember — applies `updatedPermissions`, defaulting to the
    /// CLI's own suggestions.
    func allowAlways(
        updatedInput: JSONValue? = nil, updatedPermissions: [PermissionUpdate]? = nil
    ) -> PermissionDecision {
        .allow(updatedInput: updatedInput, updatedPermissions: updatedPermissions ?? suggestions)
    }

    /// Refuse and end the turn: `"User rejected {verb} {what}"`.
    func deny() -> PermissionDecision {
        let verb = Self.toolVerbs[toolName] ?? "using"
        let what = describedInput
        return .deny(
            message: what.isEmpty ? "User rejected \(verb)" : "User rejected \(verb) \(what)",
            interrupt: true)
    }

    /// Refuse but let the model continue with the user's instructions.
    func deny(feedback: String) -> PermissionDecision {
        .deny(message: Self.feedbackTemplate + feedback, interrupt: false)
    }

    private var describedInput: String {
        if let v = input["command"]?.stringValue { return "command: \(v)" }
        if let v = input["file_path"]?.stringValue { return "file: \(v)" }
        if let v = input["path"]?.stringValue { return "path: \(v)" }
        if let v = input["pattern"]?.stringValue { return "pattern: \(v)" }
        return ""
    }
}

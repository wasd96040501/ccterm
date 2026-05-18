import AgentSDK
import Foundation

/// Categorises a `PermissionRequest` by its `toolName` so the
/// `PermissionCardView` can dispatch to a category-specific body
/// renderer. Mirrors the per-tool surfaces in the upstream CLI
/// (`src/components/permissions/*PermissionRequest`) — Bash, file
/// writes (Edit / Write / Sed-as-Edit), notebook edits, filesystem
/// reads (Read / Glob / Grep), web fetch, plan-mode enter/exit,
/// sub-agent (Task / Agent), Skill, AskUserQuestion, MCP tools
/// (`mcp__*`), and a generic fallback for everything else.
enum PermissionCardKind: Equatable {
    case bash
    case powerShell
    case sedEdit
    case fileEdit
    case fileWrite
    case notebookEdit
    case filesystemRead
    case webFetch
    case enterPlanMode
    case exitPlanMode
    case taskAgent
    case skill
    case askUserQuestion
    case mcp
    case unknown

    /// Maps a `PermissionRequest` to its category. The `command` key
    /// is inspected for Bash so a sed-in-place substitution is
    /// surfaced as a file edit instead of a shell run, matching the
    /// upstream behaviour where `BashPermissionRequest` delegates to
    /// `SedEditPermissionRequest` when `parseSedEditCommand` matches.
    static func kind(for request: PermissionRequest) -> PermissionCardKind {
        switch request.toolName {
        case "Bash":
            if let command = request.rawInput["command"] as? String,
                SedEditParser.parse(command) != nil
            {
                return .sedEdit
            }
            return .bash
        case "PowerShell":
            return .powerShell
        case "Edit", "MultiEdit", "FileEdit":
            return .fileEdit
        case "Write", "FileWrite":
            return .fileWrite
        case "NotebookEdit":
            return .notebookEdit
        case "Read", "Glob", "Grep", "FileRead":
            return .filesystemRead
        case "WebFetch":
            return .webFetch
        case "EnterPlanMode":
            return .enterPlanMode
        case "ExitPlanMode", "ExitPlanModeV2":
            return .exitPlanMode
        case "Task", "Agent":
            return .taskAgent
        case "Skill":
            return .skill
        case "AskUserQuestion":
            return .askUserQuestion
        default:
            if request.toolName.hasPrefix("mcp__") {
                return .mcp
            }
            return .unknown
        }
    }

}

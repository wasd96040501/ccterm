import AgentSDK
import Foundation

/// Copy helpers for the permission card — the one-line headline and the
/// most-informative `rawInput` parameter. SwiftUI-free (used only via
/// `String(localized:)` + the `PermissionRequest` / `PermissionCardKind`
/// models), so the AppKit card chrome (`PermissionCardContentView`) and the
/// per-kind body builders can read them without any SwiftUI dependency.
///
/// Lifted verbatim out of the deleted SwiftUI `PermissionCardView.swift` during
/// the D8 dead-SwiftUI sweep — the getters are reused-verbatim (migration plan
/// §4.4 reusedVerbatim: `PermissionCardStrings` is on the REUSE list).
enum PermissionCardStrings {

    /// One-line headline. Falls back to a generic verb when the tool
    /// isn't in the curated list.
    static func title(for request: PermissionRequest) -> String {
        let verb = toolVerb(request.toolName, kind: PermissionCardKind.kind(for: request))
        return String(localized: "Claude wants to \(verb)")
    }

    /// The most informative single field from `rawInput`, in the
    /// order Anthropic's CLI prefers for its own preview text.
    /// Consumed by the AppKit fallback body for kinds without a
    /// dedicated renderer.
    static func parameter(for request: PermissionRequest) -> String? {
        let candidates = ["command", "file_path", "path", "pattern", "url"]
        for key in candidates {
            if let v = request.rawInput[key] as? String, !v.isEmpty {
                return v
            }
        }
        return nil
    }

    private static func toolVerb(_ name: String, kind: PermissionCardKind) -> String {
        switch kind {
        case .bash: return String(localized: "run a shell command")
        case .powerShell: return String(localized: "run a PowerShell command")
        case .sedEdit, .fileEdit: return String(localized: "edit a file")
        case .fileWrite: return String(localized: "write a file")
        case .notebookEdit: return String(localized: "edit a notebook")
        case .filesystemRead:
            switch name {
            case "Glob": return String(localized: "search for files")
            case "Grep": return String(localized: "search file contents")
            default: return String(localized: "read a file")
            }
        case .webFetch: return String(localized: "fetch a web page")
        case .enterPlanMode: return String(localized: "enter plan mode")
        case .exitPlanMode: return String(localized: "exit plan mode")
        case .taskAgent: return String(localized: "run a sub-task")
        case .skill: return String(localized: "run a skill")
        case .askUserQuestion: return String(localized: "ask you a question")
        case .mcp: return String(localized: "use \(name)")
        case .unknown: return String(localized: "use \(name)")
        }
    }
}

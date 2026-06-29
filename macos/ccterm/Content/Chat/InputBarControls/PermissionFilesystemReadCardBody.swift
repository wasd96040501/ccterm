import AgentSDK
import Foundation

/// Body for `.filesystemRead` permission requests (Read / Glob /
/// Grep / FileRead). Mirrors `FilesystemPermissionRequest` upstream:
/// a tool-name label paired with the primary parameter rendered in
/// monospace — `file_path` for Read, `pattern` for Glob/Grep — and a
/// secondary "path: …" line for the Glob/Grep search root.
///
/// Upstream falls back to a generic dialog when the tool's
/// `getPath(input)` returns null; this body folds that branch in by
/// showing whichever field is populated. The decision buttons stay
/// on the shared chrome — no per-tool branching.
struct PermissionFilesystemReadCardBody {
    let request: PermissionRequest

    // MARK: - Data

    /// `Read` / `Glob` / `Grep` / `FileRead` are the only inputs
    /// `kind(for:)` routes here. We expose the literal tool name so
    /// tests can pin per-tool behaviour without a re-derived enum.
    var toolName: String { request.toolName }

    /// Headline label for the tool: localised, sentence-case verb.
    /// `Read` and `FileRead` are surfaced as "Read" since upstream
    /// uses the same `userFacingName`.
    var toolLabel: String {
        switch toolName {
        case "Glob": return String(localized: "Glob")
        case "Grep": return String(localized: "Grep")
        default: return String(localized: "Read")
        }
    }

    /// SF Symbols icon that visually matches the operation. Read =
    /// document, Glob = file-search wildcard, Grep = magnifying
    /// glass on text.
    var iconName: String {
        switch toolName {
        case "Glob": return "doc.text.magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        default: return "doc.text"
        }
    }

    /// Primary monospace line — the main thing the agent wants to
    /// touch. Read → `file_path`; Glob/Grep → the `pattern`.
    /// Returns `nil` when the field is missing or empty so the body
    /// renders the headline alone instead of an "—" placeholder.
    var primary: String? {
        switch toolName {
        case "Glob", "Grep":
            return string(forKeys: ["pattern"])
        default:
            return string(forKeys: ["file_path", "filePath", "path"])
        }
    }

    /// Secondary monospace line, prefixed `path:` / `output_mode:`
    /// so the user can tell which knob is which. Glob/Grep only —
    /// Read has nothing useful to put here.
    var secondary: String? {
        switch toolName {
        case "Glob":
            if let path = string(forKeys: ["path"]) {
                return String(localized: "path: \(path)")
            }
            return nil
        case "Grep":
            var parts: [String] = []
            if let path = string(forKeys: ["path"]) {
                parts.append(String(localized: "path: \(path)"))
            }
            if let mode = string(forKeys: ["output_mode", "outputMode"]) {
                parts.append(String(localized: "mode: \(mode)"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return nil
        }
    }

    /// Pull the first non-empty string for any of `keys` — covers
    /// snake_case (current CLI) and camelCase (older builds).
    private func string(forKeys keys: [String]) -> String? {
        for key in keys {
            if let v = request.rawInput[key] as? String, !v.isEmpty {
                return v
            }
        }
        return nil
    }
}

import AgentSDK
import Foundation

/// Body for `.mcp` permission requests (tools whose name starts
/// with `mcp__`). Upstream has no dedicated component — these fall
/// through to `FallbackPermissionRequest`.
///
/// We parse the canonical `mcp__<server>__<tool>` triple so the user
/// can see both the originating MCP server (the trust boundary) and
/// the bare tool name. The full `rawInput` is rendered as
/// pretty-printed JSON inside a 200pt-cap monospace scroll —
/// matching the shape of `taskAgent` / `notebook` bodies.
///
/// `description` (when the agent supplied one) is dimmed under the
/// headline so a chatty MCP doesn't dilute the surface.
struct PermissionMcpCardBody {
    let request: PermissionRequest

    // MARK: - Data

    /// Parsed triple from `mcp__<server>__<tool>`. Returns `nil` when
    /// the tool name doesn't match the prefix — but `kind(for:)` only
    /// routes here for names that do, so the body always has at
    /// least a `server` and `tool` to render.
    var components: (server: String, tool: String)? {
        let name = request.toolName
        guard name.hasPrefix("mcp__") else { return nil }
        let stripped = String(name.dropFirst("mcp__".count))
        let parts = stripped.components(separatedBy: "__")
        switch parts.count {
        case 0: return nil
        case 1:
            // No tool segment — server name alone. Surface the server
            // as both pieces so the headline isn't blank.
            return (parts[0], parts[0])
        default:
            // `mcp__server__a__b` — the upstream convention is that
            // everything after the second `__` is the tool name,
            // joined back with `__`.
            let server = parts[0]
            let tool = parts.dropFirst().joined(separator: "__")
            return (server, tool)
        }
    }

    var serverName: String? { components?.server }
    var toolName: String? { components?.tool }

    /// Display name for the tool. Falls back to the literal
    /// `request.toolName` when parsing fails — better the user sees
    /// `mcp__weird` than an empty headline.
    var toolDisplayName: String {
        toolName ?? request.toolName
    }

    var description: String? {
        let raw = request.rawInput["description"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// Pretty-printed JSON for the input map. Sorted keys so the
    /// order is stable across renders — MCP servers don't guarantee
    /// any particular key order. Returns `nil` when there's nothing
    /// to show (empty rawInput) and `""` when serialisation fails so
    /// the view collapses the row.
    var inputJSON: String? {
        let dict = request.rawInput
        guard !dict.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(dict) else {
            return ""
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

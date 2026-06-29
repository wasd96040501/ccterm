import AgentSDK
import Foundation

/// Body for `.taskAgent` permission requests (Task / Agent). Upstream
/// has no dedicated component — these fall through to
/// `FallbackPermissionRequest`. We surface the structured input so
/// the user can read the sub-task before approving:
///
/// - `subagent_type` (Explore / Plan / general-purpose / …) as the
///   headline so the trust budget reads "this is a sub-Explore",
///   not a generic "Task".
/// - `description` (3–5 word task summary) dimmed below.
/// - `prompt` in a 200pt-cap monospace scroll so a long prompt
///   doesn't push the decision buttons off-screen.
/// - `isolation == "worktree"` surfaced as a chip so the user knows
///   the agent will operate inside a throw-away copy of the repo.
/// - `model` override surfaced as a secondary chip when set —
///   `inherit` is the default and is intentionally hidden.
struct PermissionTaskAgentCardBody {
    let request: PermissionRequest

    // MARK: - Data

    /// The sub-agent's `subagent_type` (`"Explore"`, `"Plan"`, etc.).
    /// `nil` when omitted — upstream defaults to `general-purpose`
    /// at call time, so we surface that fallback as the headline.
    var subagentType: String? {
        let raw =
            (request.rawInput["subagent_type"] as? String)
            ?? (request.rawInput["subagentType"] as? String)
        return raw?.isEmpty == false ? raw : nil
    }

    var description: String? {
        let raw = request.rawInput["description"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    var prompt: String? {
        let raw = request.rawInput["prompt"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// One of `"worktree"` (the only currently public option) or
    /// `nil`. Surface presence as a chip — the literal value is the
    /// noteworthy detail.
    var isolation: String? {
        let raw = request.rawInput["isolation"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// `sonnet` / `opus` / `haiku` model override. `nil` falls back
    /// to the parent agent's model so the chip is hidden — surface
    /// only the explicit override.
    var modelOverride: String? {
        let raw = request.rawInput["model"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// Headline subtitle. The sub-agent type takes precedence; falls
    /// back to "Run sub-task" when omitted (the call-time default
    /// is `general-purpose`, which isn't a useful display name).
    var subtitle: String {
        if let t = subagentType {
            return String(localized: "Run \(t) agent")
        }
        return String(localized: "Run sub-task")
    }

    /// Ordered list of chip labels for the metadata row. Empty when
    /// neither `isolation` nor a `model` override is present.
    var chips: [String] {
        var out: [String] = []
        if isolation == "worktree" {
            out.append(String(localized: "Isolated worktree"))
        } else if let isolation {
            // Any other isolation value (e.g. "remote") — render the
            // literal so the user knows what they're approving.
            out.append(isolation)
        }
        if let modelOverride {
            out.append(String(localized: "model: \(modelOverride)"))
        }
        return out
    }
}

import AgentSDK
import SwiftUI

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
struct PermissionTaskAgentCardBody: View {
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        chipView(chip)
                    }
                }
            }
            if let prompt, !prompt.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    @ViewBuilder
    private func chipView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
    }
}

#Preview("Explore agent · worktree") {
    PermissionTaskAgentCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-1",
            toolName: "Task",
            input: [
                "subagent_type": "Explore",
                "description": "Find permission card body sites",
                "prompt":
                    "Locate every file under macos/ccterm/Content/Chat/InputBarControls that defines a PermissionXxxCardBody view and report their paths.",
                "isolation": "worktree",
                "model": "sonnet",
            ])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Generic sub-task · no chips") {
    PermissionTaskAgentCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-2",
            toolName: "Task",
            input: [
                "description": "Draft release notes",
                "prompt":
                    "Summarise the last five merged PRs into a customer-facing release note.",
            ])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Plan agent · model override") {
    PermissionTaskAgentCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-3",
            toolName: "Agent",
            input: [
                "subagent_type": "Plan",
                "description": "Plan migration",
                "prompt":
                    "Plan the migration from the old permission dialog to the new card.",
                "model": "opus",
            ])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

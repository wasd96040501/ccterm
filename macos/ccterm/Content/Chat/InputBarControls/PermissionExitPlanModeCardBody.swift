import AgentSDK
import Foundation
import SwiftUI

/// Body for `.exitPlanMode` permission requests
/// (`ExitPlanMode` / `ExitPlanModeV2`). Upstream's
/// `ExitPlanModePermissionRequest` (the largest permission UI by
/// far) is a fullscreen-style review surface with a markdown
/// renderer, attachment support, an in-line `$EDITOR` prompt, and a
/// many-branch decision matrix that flips session-level state.
///
/// **v1 in ccterm:** render the plan as plain monospaced text in a
/// 480pt-cap scroll so a long plan stays inspectable without
/// pushing the decision buttons off-screen. The three shared
/// buttons (Allow once / Allow always / Deny) substitute for the
/// upstream branch matrix — accept-edits-keep-context, auto-mode,
/// ultraplan, etc. need session-mode plumbing that isn't here yet
/// and are tracked as follow-up work.
///
/// **V2 fallback:** `ExitPlanModeV2` writes the plan to a file
/// instead of inlining it; the file path arrives via tool context
/// we don't surface in `rawInput`. When we can't read a plan body
/// we show a brief note so the user still knows what the request
/// is — same trust budget, different inputs.
struct PermissionExitPlanModeCardBody: View {
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let plan, !plan.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(plan)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 480)
            } else {
                Text(emptyPlanHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    /// True when the tool is `ExitPlanModeV2`. V2 doesn't inline the
    /// plan in `rawInput` — the agent writes a plan file and the
    /// CLI reads it back. We don't have access to that file here, so
    /// the body falls back to a short explanatory hint.
    var isV2: Bool { request.toolName == "ExitPlanModeV2" }

    /// Plan markdown the agent is asking the user to approve. v1
    /// only — V2 stores the plan elsewhere.
    var plan: String? {
        guard !isV2 else { return nil }
        let raw = request.rawInput["plan"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    var headline: String {
        String(localized: "Review the plan to leave plan mode?")
    }

    var emptyPlanHint: String {
        if isV2 {
            return String(
                localized:
                    "Plan stored in a file; review it in the transcript before approving."
            )
        }
        return String(localized: "No plan body — review the transcript before approving.")
    }
}

#Preview("ExitPlanMode · with plan") {
    PermissionExitPlanModeCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-1",
            toolName: "ExitPlanMode",
            input: [
                "plan": """
                    ## Refactor permission cards

                    1. Extract per-kind body views into their own files.
                    2. Add #Preview to each body so designers can iterate.
                    3. Wire the dispatch into PermissionCardView.
                    4. Cover the new bodies with unit tests.

                    ## Risks

                    - Snapshot diffs may shift; re-bless after review.
                    - Localisation keys need translation updates.
                    """
            ])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("ExitPlanModeV2 · file-backed") {
    PermissionExitPlanModeCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-2",
            toolName: "ExitPlanModeV2",
            input: [:])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("ExitPlanMode · empty plan") {
    PermissionExitPlanModeCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-3",
            toolName: "ExitPlanMode",
            input: [:])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

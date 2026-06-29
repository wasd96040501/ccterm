import AgentSDK
import Foundation

/// Body for `.enterPlanMode` permission requests. Mirrors the
/// upstream `EnterPlanModePermissionRequest` shape: a static
/// explanation block, four bullets describing what plan mode does,
/// and a closing reassurance that no code changes happen until the
/// plan is approved.
///
/// The bullets are hard-coded — they're product copy, not data from
/// the agent. Upstream renders them dim; we do the same with
/// `.foregroundStyle(.secondary)`.
///
/// The CLI's dedicated accent color (`color="planMode"`) is not
/// plumbed into `PermissionCardView` yet — adding a `tint:` knob is
/// follow-up work tracked in the handoff. The body remains
/// recognisable on the existing `.barSurface` chrome via the
/// "wand.and.stars" icon row.
struct PermissionEnterPlanModeCardBody {
    let request: PermissionRequest

    /// Bullet copy matching the upstream Ink layout verbatim. Kept
    /// internal (not private) so tests can pin the exact phrasing
    /// without re-deriving from the view body.
    static let bullets: [String] = [
        String(localized: "Explore the codebase thoroughly"),
        String(localized: "Identify existing patterns"),
        String(localized: "Design an implementation strategy"),
        String(localized: "Present a plan for your approval"),
    ]

    // MARK: - Copy

    var intro: String {
        String(
            localized:
                "Claude wants to enter plan mode to explore and design an implementation approach."
        )
    }

    var bulletHeader: String {
        String(localized: "In plan mode, Claude will:")
    }

    var closing: String {
        String(localized: "No code changes will be made until you approve the plan.")
    }
}

import Foundation

/// `generic` child payload — catch-all for tool kinds without a
/// dedicated child layout (Skill / Cron* / Send* / Todo* / Enter* /
/// Exit* mode toggles / Task ops / TeamCreate / ToolSearch / unknown).
///
/// Header-only — the row reads as a single label line with no chevron,
/// matching the old `PlaceholderChildRenderer`'s `[Tool: <name>]`
/// placeholder but using whatever the caller chose to put in `label`
/// (typically the tool's case name or a one-line summary).
struct GenericChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense form / fallback (e.g. `"Used <tool>"`).
    let label: String
    /// Progressive form (e.g. `"Using <tool>"`). Generic tools
    /// without a dedicated child layout fall through here, so the
    /// caller picks whatever phrase reads best.
    let activeLabel: String
}

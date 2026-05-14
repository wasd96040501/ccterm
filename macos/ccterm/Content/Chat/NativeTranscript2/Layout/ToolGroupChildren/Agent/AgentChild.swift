import Foundation

/// `agent` child payload — Task/Agent sub-agent tool. Body shows
/// the progress trail (a list of one-line entries) and, once the
/// sub-agent finished, the rendered output as plain text. Both are
/// rendered into their own sub-cards via `TextCardSection`.
///
/// `label` is the human-facing header text (e.g. `"Ran agent 'audit'"`).
struct AgentChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense form (e.g. `"Agent: <description>"`).
    let label: String
    /// Progressive form (e.g. `"Running agent: <description>"`).
    let activeLabel: String
    let description: String
    /// Progress entries — one short line each (e.g. "Searching
    /// documentation…", "Found 12 matches"). Rendered as a bullet
    /// list with `↳` prefix per entry. Empty list = the sub-agent
    /// didn't emit progress, the layout suppresses the progress
    /// card and only renders `output` (if any).
    let progress: [String]
    /// Final rendered output. Plain text today — markdown
    /// re-parsing is a future refinement (would belong to a shared
    /// `Markdown → [InlineNode]` helper, not to this child's layout).
    let output: String?
}

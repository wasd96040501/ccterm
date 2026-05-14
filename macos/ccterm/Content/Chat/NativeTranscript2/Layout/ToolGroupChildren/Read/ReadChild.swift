import Foundation

/// `read` child payload — file-read tool. Header-only (no expandable
/// body) — the row's value is "we read this file"; the file's
/// contents live elsewhere (e.g. an inline assistant message). `label`
/// is the human-facing header text (e.g. `"Read Sources/Greeter.swift"`,
/// past-tense by default — the active phrasing belongs to the group
/// header that wraps these children).
///
/// `filePath` is kept separate from `label` so future layouts can
/// reuse it (e.g. routing the row to an inspector) without parsing
/// the localized label. Nothing in the current layout reads it.
struct ReadChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense / completed-form header text (e.g.
    /// `"Read Sources/Greeter.swift"`). Routed via
    /// `Child.headerLabel(for:)` for any non-`.running` status.
    let label: String
    /// Progressive / running-form header text (e.g.
    /// `"Reading Sources/Greeter.swift"`). Used when the child's
    /// `ToolStatus` is `.running`.
    let activeLabel: String
    let filePath: String
}

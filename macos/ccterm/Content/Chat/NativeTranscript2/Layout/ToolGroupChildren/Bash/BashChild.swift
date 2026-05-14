import Foundation

/// `bash` child payload — shell tool. Expanded body renders the
/// `command` (monospaced) plus the merged `stdout` / `stderr` streams
/// stacked vertically, each in its own rounded sub-card. `nil` streams
/// (still running) and empty strings are skipped so a freshly-launched
/// command shows just the command card.
///
/// `label` is the human-facing header text (e.g. `"Ran 'make build'"`).
struct BashChild: Equatable, Sendable {
    let id: UUID
    let label: String
    let command: String
    /// Captured stdout. `nil` while the command is still running; an
    /// empty string is treated the same as `nil` for rendering.
    let stdout: String?
    /// Captured stderr.
    let stderr: String?
}

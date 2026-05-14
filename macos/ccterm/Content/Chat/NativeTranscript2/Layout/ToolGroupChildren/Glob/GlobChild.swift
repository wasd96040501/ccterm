import Foundation

/// `glob` child payload — filename pattern tool. Body lists the
/// matched paths in a single rounded card. When the tool returned
/// `truncated == true`, an "… truncated" trailer line is appended
/// inside the same card (same band as the paths, secondary tint).
///
/// `label` is the human-facing header text (e.g. `"Globbed '**/*.swift'"`).
struct GlobChild: Equatable, Sendable {
    let id: UUID
    let label: String
    let pattern: String
    let filenames: [String]
    let truncated: Bool
}

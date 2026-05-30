import Foundation

/// `glob` child payload — filename pattern tool. Body lists the
/// matched paths in a single rounded card. When the tool returned
/// `truncated == true`, an "… truncated" trailer line is appended
/// inside the same card (same band as the paths, secondary tint).
///
/// `label` is the human-facing header text (e.g. `"Globbed '**/*.swift'"`).
struct GlobChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense form (e.g. `"Globbed \"**/*.swift\""`).
    let label: String
    /// Progressive form (e.g. `"Globbing \"**/*.swift\""`).
    let activeLabel: String
    let pattern: String
    let filenames: [String]
    let truncated: Bool
    /// Wrapper-level error text (`tool_result.is_error == true`), stripped
    /// of the `<tool_use_error>` envelope. `nil` on success. Rendered as a
    /// uniform red error card below the body by `ToolGroupChildLayout`.
    var errorText: String? = nil
}

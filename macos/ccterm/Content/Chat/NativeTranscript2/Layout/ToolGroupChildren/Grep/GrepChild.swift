import Foundation

/// `grep` child payload — pattern search tool. Body lists the
/// matching `filenames` and, when the tool returned an inline
/// preview, the `content` block (monospaced).
///
/// `label` is the human-facing header text (e.g. `"Grepped 'TODO'"`).
struct GrepChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense form (e.g. `"Searched \"TODO\""`).
    let label: String
    /// Progressive form (e.g. `"Searching \"TODO\""`). Used when
    /// the child's `ToolStatus` is `.running`.
    let activeLabel: String
    let pattern: String
    let filenames: [String]
    /// Optional inline preview from the tool result — usually
    /// `<path>:<line>:<text>` rows joined by newlines. Rendered
    /// verbatim in a second card below the filenames card. `nil`
    /// when the tool returned filenames only.
    let content: String?
    /// Wrapper-level error text (`tool_result.is_error == true`), stripped
    /// of the `<tool_use_error>` envelope. `nil` on success. Rendered as a
    /// uniform red error card below the body by `ToolGroupChildLayout`.
    var errorText: String? = nil
}

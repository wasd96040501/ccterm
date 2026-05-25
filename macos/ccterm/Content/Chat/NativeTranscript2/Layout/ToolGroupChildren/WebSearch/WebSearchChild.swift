import Foundation

/// `webSearch` child payload — search engine tool. Body lists each
/// hit's `(title, url, snippet)` triple — title in semibold body
/// size, url monospaced muted, optional snippet on a third line in
/// secondary tint.
///
/// `label` is the human-facing header text (e.g. `"Searched 'foo'"`).
struct WebSearchChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense form (e.g. `"Searched \"foo\""`).
    let label: String
    /// Progressive form (e.g. `"Searching \"foo\""`).
    let activeLabel: String
    let query: String
    let results: [Result]
    /// Wrapper-level error text (`tool_result.is_error == true`), stripped
    /// of the `<tool_use_error>` envelope. `nil` on success. Rendered as a
    /// uniform red error card below the body by `ToolGroupChildLayout`.
    var errorText: String? = nil

    struct Result: Equatable, Sendable {
        let title: String
        let url: String
        let snippet: String?
    }
}

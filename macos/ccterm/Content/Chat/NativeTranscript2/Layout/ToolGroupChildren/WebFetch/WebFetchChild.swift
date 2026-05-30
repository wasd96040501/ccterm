import Foundation

/// `webFetch` child payload — HTTP fetch tool. Body shows the
/// fetched response as plain text inside a muted card. The old
/// SwiftUI block rendered the body as markdown; the native renderer
/// keeps it verbatim today — embedding a markdown sub-parser is a
/// future refinement (would belong to a shared
/// `Markdown → [InlineNode]` helper, not to this child's layout).
///
/// `label` is the human-facing header text (e.g. `"Fetched
/// https://example.com"`).
struct WebFetchChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense form (e.g. `"Fetched https://example.com"`).
    let label: String
    /// Progressive form (e.g. `"Fetching https://example.com"`).
    let activeLabel: String
    let url: String
    let httpStatus: Int?
    /// Response body (text). `nil` when the request is still in
    /// flight or completed with no body (e.g. a 204).
    let result: String?
    /// Wrapper-level error text (`tool_result.is_error == true`), stripped
    /// of the `<tool_use_error>` envelope. `nil` on success. Rendered as a
    /// uniform red error card below the body by `ToolGroupChildLayout`.
    var errorText: String? = nil
}

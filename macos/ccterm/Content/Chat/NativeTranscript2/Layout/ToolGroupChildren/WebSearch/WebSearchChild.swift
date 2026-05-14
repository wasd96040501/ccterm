import Foundation

/// `webSearch` child payload — search engine tool. Body lists each
/// hit's `(title, url, snippet)` triple — title in semibold body
/// size, url monospaced muted, optional snippet on a third line in
/// secondary tint.
///
/// `label` is the human-facing header text (e.g. `"Searched 'foo'"`).
struct WebSearchChild: Equatable, Sendable {
    let id: UUID
    let label: String
    let query: String
    let results: [Result]

    struct Result: Equatable, Sendable {
        let title: String
        let url: String
        let snippet: String?
    }
}

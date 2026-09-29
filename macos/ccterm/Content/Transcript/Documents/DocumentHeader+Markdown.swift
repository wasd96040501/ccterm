import Foundation

/// The header of a document set as markdown — a search, a page fetched, an
/// agent, the task list, a task's news, a command's output, a compaction's
/// summary, anything else.
nonisolated extension DocumentHeader {
    static func markdown(_ content: DocumentContent) -> DocumentHeader {
        let title = String(localized: "Document")
        return DocumentHeader(tile: Tile(glyph: .tool(.other), state: .done), crumbs: [title], title: title)
    }
}

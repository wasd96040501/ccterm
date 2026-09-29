import Foundation

/// A file document's header (03-file.md "The frame"): the path as Xcode's
/// jump bar, relative to the session's directory, and the stat — `+12 −3`,
/// `New · 55 lines`, `Lines 40–120 of 880`.
nonisolated extension DocumentHeader {
    /// `content` is `.change`, `.newFile` or `.read`.
    static func source(_ content: DocumentContent, workingDirectory: String?) -> DocumentHeader {
        let title = String(localized: "File")
        return DocumentHeader(tile: Tile(glyph: .tool(.read), state: .done), crumbs: [title], title: title)
    }
}

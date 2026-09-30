import Foundation

/// The 20-pt line above words someone other than Claude put on the page — a
/// message from another agent or a plan — naming who, or what, it is.
nonisolated struct Caption: Sendable, Equatable {
    enum Glyph: Sendable, Equatable {
        /// The sidebar's glyph for that party, in the sidebar's colour.
        case subagent, session, coordinator, plugin
        /// A tool tile — a plan's, coral while it waits for the reader.
        case tile(Tile)
    }

    let glyph: Glyph
    let text: String
}

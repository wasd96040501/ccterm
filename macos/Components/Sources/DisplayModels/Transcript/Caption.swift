import Foundation

/// The 20-pt line above words someone other than Claude put on the page — a
/// message from another agent or a plan — naming who, or what, it is.
public nonisolated struct Caption: Sendable, Equatable {
    public enum Glyph: Sendable, Equatable {
        /// The sidebar's glyph for that party, in the sidebar's colour.
        case subagent, session, coordinator, plugin
        /// A tool tile — a plan's, coral while it waits for the reader.
        case tile(Tile)
    }

    public let glyph: Glyph
    public let text: String
    /// After the name, in 11-pt tertiary: when a plugin spoke (*Started this
    /// turn*, *While Claude worked*).
    public var detail: String?

    public init(glyph: Glyph, text: String, detail: String? = nil) {
        self.glyph = glyph
        self.text = text
        self.detail = detail
    }
}

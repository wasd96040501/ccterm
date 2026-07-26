import Foundation

/// One row in the flat history transcript, carrying a single render
/// payload. Value type — the row list is built once by
/// `TranscriptRowBuilder` at load and is immutable thereafter (one-shot
/// blocking load, no live mutation). `NSTableView` addresses rows by
/// index, so there is no per-row reference handle.
///
/// Layering: Model. No `import AppKit`, no UI logic — it only carries the
/// data + the already-decided render payload. Typesetting a payload is the
/// store's job; picking the view that draws it is the controller's.
struct TranscriptRow: Identifiable {
    /// Stable identity (SHA-derived via `StableBlockID`), used as the
    /// layout-cache key and the selection key.
    let id: UUID
    let content: Content

    init(id: UUID, content: Content) {
        self.id = id
        self.content = content
    }

    /// The render payload. Each case maps to one typeset measure in
    /// `TranscriptLayoutCache` and one row view in the controller.
    enum Content {
        /// A markdown top block (heading / paragraph / list / table /
        /// codeBlock / blockquote / thematicBreak), a user bubble, or a
        /// user-attachments strip — anything a single existing `Block`
        /// renders.
        case block(Block)
        /// A tool group's aggregated header title (e.g. "Edited 3 files ·
        /// Searched 1 pattern"). Rendered title-only; the group's
        /// individual tools are not shown (a richer tool UI is deferred).
        case groupHeader(title: String)
    }
}

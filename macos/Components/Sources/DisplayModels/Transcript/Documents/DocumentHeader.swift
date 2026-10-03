import DisplayModels
import Foundation

/// What a document's jump bar and tab say about it — the words only; the
/// jump bar draws them (design/transcript/README.md "Opening a document",
/// 02-command.md, 03-file.md).
///
/// Every document has the bar, and every one a transcript has a row for has
/// *Show in Transcript* in the same place; the bar itself adds only that.
/// The app words one from a `Document` (`DocumentHeader(_:)`).
public nonisolated struct DocumentHeader: Sendable, Equatable {
    /// The kind's tile, in the call's state.
    public var tile: Tile
    /// The jump bar's path, outermost first: a file's folders then its name
    /// (folders collapse from the middle when narrow, the name never does);
    /// otherwise one crumb, the title.
    public var crumbs: [String]
    /// Trailing facts: a change's `+12 −3`, `New · 55 lines`,
    /// `Lines 40–120 of 880`.
    public var stat: StyledText
    /// The tab's title.
    public var title: String
    /// Whether the bar offers *Show in Transcript*: a document the transcript
    /// has no row for (a session's log, its context) has no way back to one.
    public var showsTranscriptJump: Bool

    public init(
        tile: Tile, crumbs: [String], stat: StyledText = StyledText(), title: String,
        showsTranscriptJump: Bool = true
    ) {
        self.tile = tile
        self.crumbs = crumbs
        self.stat = stat
        self.title = title
        self.showsTranscriptJump = showsTranscriptJump
    }
}

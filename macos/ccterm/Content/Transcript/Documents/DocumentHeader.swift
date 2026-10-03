import DisplayModels
import Foundation

/// What a document's jump bar and tab say about it — the words only; the
/// jump bar draws them (design/transcript/README.md "Opening a document",
/// 02-command.md, 03-file.md).
///
/// Every document has the bar, and every one a transcript has a row for has
/// *Show in Transcript* in the same place; the bar itself adds only that.
nonisolated struct DocumentHeader: Sendable, Equatable {
    /// The kind's tile, in the call's state.
    var tile: Tile
    /// The jump bar's path, outermost first: a file's folders then its name
    /// (folders collapse from the middle when narrow, the name never does);
    /// otherwise one crumb, the title.
    var crumbs: [String]
    /// Trailing facts: a change's `+12 −3`, `New · 55 lines`,
    /// `Lines 40–120 of 880`.
    var stat: StyledText
    /// The tab's title.
    var title: String
    /// Whether the bar offers *Show in Transcript*: a document the transcript
    /// has no row for (a session's log, its context) has no way back to one.
    var showsTranscriptJump: Bool

    init(
        tile: Tile, crumbs: [String], stat: StyledText = StyledText(), title: String,
        showsTranscriptJump: Bool = true
    ) {
        self.tile = tile
        self.crumbs = crumbs
        self.stat = stat
        self.title = title
        self.showsTranscriptJump = showsTranscriptJump
    }

    /// The header of `document`, worded by the kind of document it is.
    init(_ document: Document) {
        switch document.content {
        case .command(let call):
            self = Self.command(call)
        case .shellCommand(let command):
            self = Self.shellCommand(command)
        case .change, .newFile, .read:
            self = Self.source(document.content, workingDirectory: document.workingDirectory)
        default:
            self = Self.markdown(document.content)
        }
    }
}

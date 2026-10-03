import DisplayModels
import Foundation

/// One line of work, ready to draw: a run's row, one item of an expanded
/// run, a background task's news. The same five parts in the same places
/// every time (design/transcript/01-run.md "Anatomy"):
///
/// ```
/// ▢  text ········· detail   exceptions            meta
/// ```
///
/// Built once, when the page is built, by `WorkLineWriter` — a view only
/// draws it, and `heightOfRow` never has to compose a sentence.
nonisolated struct WorkLine: Sendable, Equatable {
    var tile: Tile
    /// What happened, in the work voice. Cut at the tail when the line is
    /// short of room.
    var text: StyledText
    /// A command's first line, a file's folder: monospaced, tertiary, after
    /// the text. Cut first.
    var detail: String?
    /// The detail is words, not code — a message's summary, the advice's first
    /// line (`.callsub`): the text's face, tertiary.
    var detailIsWords = false
    /// *· 1 failed*, *· Interrupted*: set apart from the text and never cut.
    var exceptions: StyledText
    /// Trailing: lines added and removed, time, a count. Monospaced digits.
    var meta: StyledText
}

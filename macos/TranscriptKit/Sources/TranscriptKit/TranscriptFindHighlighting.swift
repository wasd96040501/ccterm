import AppKit

/// A view that draws a find's matches — adopted by a `.view` row's view so that a
/// find reaches the rows the host draws, not only the ones the transcript does.
///
/// **One requirement, and it is the display half only.** Where the matches are is
/// asked of the delegate, through
/// `TranscriptViewDelegate.transcriptView(_:findMatchesOf:inRow:)`, because a find
/// counts every row and most rows have no view — the same split `heightOfRow` and
/// `viewForRow` draw. This is what happens once a row does have one: the
/// transcript hands back the ranges the delegate reported, and says which of them
/// the reader is on. The view never searches and never keeps the answer anywhere
/// but on screen.
///
/// The transcript's own rows adopt it too, which is the reason it exists as a
/// protocol rather than a delegate callback: there is one path that tells a row
/// about the find, whoever drew the row. `UITextSearching`'s
/// `decorate(foundTextRange:document:usingStyle:)` is the same idea, pushed one
/// range at a time; a row is small enough to be handed all of them at once.
@MainActor
public protocol TranscriptFindHighlighting: AnyObject {

    /// Shows `matches` as found text, and `current` — one of them, or `nil` — as
    /// the one the reader is on. An empty array clears whatever was shown.
    ///
    /// Called after every `viewForRow` that returns this view, so a recycled
    /// instance never carries the previous row's matches; and again whenever the
    /// find changes while the row is on screen — once per slice of a long walk,
    /// with the same arguments more often than not. So it has to be **idempotent,
    /// and cheap when nothing moved**: compare, and redraw only on a change.
    ///
    /// The ranges are in the index space the delegate reported them in, which is
    /// the host's own; the transcript compares them for equality and counts them,
    /// and nothing else.
    func setFindMatches(_ matches: [Range<Int>], current: Range<Int>?)
}

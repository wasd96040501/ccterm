import AppKit

/// A view whose find matches the transcript can show — adopted by a `.view` row's
/// view so that a find reaches the rows the host draws, not only the ones the
/// transcript does.
///
/// **The two questions `NSTextFinderClient` asks of a content view, and nothing
/// else.** Where the matches are is asked of the delegate, through
/// `TranscriptViewDelegate.transcriptView(_:findMatchesOf:inRow:)`, because a find
/// counts every row and most rows have no view — the same split `heightOfRow` and
/// `viewForRow` draw. This is what the transcript needs once a row does have one:
/// where a match is drawn, and its characters drawn again on their own. With those
/// two it presents the find the way AppKit's own find bar does — the content
/// dimmed, every match lit through it, the one the reader is on raised in yellow —
/// the same for every row, whoever drew it. The view never draws a highlight of its
/// own, never searches, and keeps nothing about the find.
///
/// The transcript's own rows adopt it too, which is why it is a protocol rather
/// than a delegate callback: one path presents a find, whoever drew the row.
///
/// The ranges are in the index space the delegate reported them in, which is the
/// host's own; the transcript hands them back unexamined.
@MainActor
public protocol TranscriptFindHighlighting: AnyObject {

    /// Where the characters in `range` are drawn, in this view's coordinate
    /// system — one rectangle per line they occupy.
    ///
    /// `NSTextFinderClient.rects(forCharacterRange:)`. The transcript lights these
    /// through its dimming and raises the current match's in yellow, so they want
    /// to be the line's height rather than the glyphs' ink: a selection's
    /// rectangles, not a hit-test's.
    func rects(forCharacterRange range: Range<Int>) -> [NSRect]

    /// Draws the glyphs for the characters in `range` — the glyphs alone, with no
    /// background, selection or decoration — into the current graphics context,
    /// which is set up in this view's coordinate system as it is for `draw(_:)`.
    ///
    /// `NSTextFinderClient.drawCharacters(in:forContentView:)`, for the find
    /// indicator: the current match is drawn again on the indicator's yellow. The
    /// transcript recolours what this draws to the indicator's text colour, so
    /// the glyphs may come in whatever colour they normally have — which is also
    /// why nothing but glyphs belongs here: a background drawn along with them
    /// would come out as a solid block.
    func drawCharacters(in range: Range<Int>)
}

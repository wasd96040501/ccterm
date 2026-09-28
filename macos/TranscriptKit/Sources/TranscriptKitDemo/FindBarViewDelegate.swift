import AppKit

/// What a find bar asks of the editor it sits in.
///
/// The commands are `NSTextFinder.Action`s — `.nextMatch`, `.previousMatch`,
/// `.hideFindInterface` — rather than a method each, so that a bar's buttons and
/// the Find menu, whose items send `performTextFinderAction(_:)` with the same
/// actions as tags, arrive at the one `switch` in the editor.
@MainActor
protocol FindBarViewDelegate: AnyObject {

    /// The query changed as it was typed or cleared. Empty means no find.
    func findBarView(_ findBarView: FindBarView, didChangeSearchString searchString: String)

    /// Return, Shift-Return, the arrows, Done and Escape.
    func findBarView(_ findBarView: FindBarView, perform action: NSTextFinder.Action)
}

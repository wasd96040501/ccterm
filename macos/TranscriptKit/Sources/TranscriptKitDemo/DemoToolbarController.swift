import AppKit

/// The window's toolbar: one `NSSearchToolbarItem`, which is the find bar.
///
/// **The system's own, not one built here.** The toolbar search item is where a
/// macOS window keeps its search — the field, its expand and collapse, ⌘F
/// focusing it — and a find row of hand-placed controls would be this demo
/// inventing chrome AppKit already has. What is added is the count and the two
/// keys: Return steps to the next hit and Shift-Return to the previous, which is
/// Safari's and Xcode's binding, and ⌘G / ⇧⌘G in the Edit menu reach the same two.
///
/// Reports intent through closures, like `ControlPanelView`, and never touches
/// the transcript.
@MainActor
final class DemoToolbarController: NSObject {

    let toolbar = NSToolbar(identifier: "TranscriptKitDemo")

    /// The query as it is typed, empty when the field is cleared.
    var onFind: ((String) -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?

    private let searchItem = NSSearchToolbarItem(itemIdentifier: .search)
    private let searchField = FindSearchField()

    /// Pending removal of the count after the query changed. See `queryDidChange`.
    private var countHide: Timer?

    /// How long a changed query's old count may stand before it is taken down.
    private static let countGrace: TimeInterval = 0.2

    override init() {
        super.init()
        // Typing searches; Return, Shift-Return and Escape are taken by the
        // delegate before the field sees them. That leaves the action one job —
        // the cancel button, which empties the field without posting a text change
        // — and `sendsWholeSearchString` keeps it to that: left at its default,
        // the field also sends the action on its own once typing pauses.
        searchField.delegate = self
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchItem.searchField = searchField

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    /// Shows `x/y` — the hit the reader is on, one-based, of how many there are.
    ///
    /// **Only for a walk that has finished**, which is the host's to decide and
    /// the reason this takes no `isComplete`: a count climbing under the typing is
    /// noise, and the one worth reading is the total.
    ///
    /// `nil` reads as a dash rather than as `1`: the hit the reader was on went
    /// away, and no match is the current one. Nothing is shown beside an empty
    /// field, whatever the caller passed — ending a find reports zero, and `0/0`
    /// there would say "no matches" where the truth is that nothing was asked.
    func setFindCount(selected: Int?, of total: Int) {
        countHide?.invalidate()
        countHide = nil
        guard !searchField.stringValue.isEmpty else { return searchField.setCount(nil) }
        searchField.setCount("\(selected.map { "\($0 + 1)" } ?? "–")/\(total)")
    }

    /// What ⌘F is wired to: the search item's own way in, which expands it if the
    /// toolbar had collapsed it to a button and puts the caret in the field.
    @objc func beginFind() {
        searchItem.beginSearchInteraction()
    }

    /// The Edit menu's Find Next / Find Previous.
    @objc func findNext() { onFindNext?() }
    @objc func findPrevious() { onFindPrevious?() }

    @objc private func searchFieldAction() {
        guard searchField.stringValue.isEmpty else { return }
        queryDidChange()
    }

    /// Hands the new query over, and takes the count down if the walk it starts
    /// has not finished shortly.
    ///
    /// Not straight away. The count beside the old query is wrong for the new one,
    /// but on an ordinary transcript the new walk finishes within a frame or two —
    /// taking the count down on every keystroke would blink it on and off as the
    /// reader types. So the old count gets a moment to be replaced, and only a walk
    /// that outlasts it leaves the field without one until it is done. An empty
    /// field has nothing to wait for.
    private func queryDidChange() {
        countHide?.invalidate()
        countHide = nil
        if searchField.stringValue.isEmpty {
            searchField.setCount(nil)
        } else {
            countHide = Timer.scheduledTimer(
                withTimeInterval: Self.countGrace, repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.searchField.setCount(nil) }
            }
        }
        onFind?(searchField.stringValue)
    }
}

extension DemoToolbarController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .search]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        itemIdentifier == .search ? searchItem : nil
    }
}

extension DemoToolbarController: NSSearchFieldDelegate {

    /// Per keystroke, rather than through the field's action, which would search
    /// only on Return — and Return here means "next".
    func controlTextDidChange(_ notification: Notification) {
        queryDidChange()
    }

    /// Return steps to the next hit, Shift-Return to the previous. Both arrive as
    /// `insertNewline(_:)`; the modifier is only on the event, so that is where it
    /// is read.
    ///
    /// Escape clears the query, which ends the find, the way it does in Finder's
    /// toolbar search. The toolbar item's own handling only ends the interaction
    /// and leaves the query standing — the highlights with it. On an empty field
    /// Escape is left to that handling, so a second press still leaves the field.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onFindPrevious?()
            } else {
                onFindNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)) where !searchField.stringValue.isEmpty:
            searchField.stringValue = ""
            queryDidChange()
            return true
        default:
            return false
        }
    }
}

extension NSToolbarItem.Identifier {
    fileprivate static let search = NSToolbarItem.Identifier("TranscriptKitDemo.search")
}

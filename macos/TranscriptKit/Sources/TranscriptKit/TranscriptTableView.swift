import AppKit

/// The transcript's table, and the two things it adds: saying when it has placed
/// its rows, and being the responder for the selection.
///
/// A find's overlay lights matches where the rows are, and the table moves rows
/// without telling anyone — a height noted, a row inserted above, a width change
/// re-tiling everything. `tile()` is where it works out the new geometry and
/// `layout()` is where row views take it, so both report; the overlay sits later
/// in the scroll view's subviews than the clip holding this table, so a layout pass
/// reaches it after the rows have moved rather than before.
///
/// The selection's half is `NSTextView`'s shape: the document view holds the focus
/// and answers Copy. Every piece of it is forwarded to its owner — the
/// transcript, which hands it to its `SelectionTracker`.
final class TranscriptTableView: NSTableView {

    /// Weak, like `TableViewAdapter`'s: the transcript owns this table. A protocol
    /// rather than the transcript's type, so the table names only the events it
    /// reports.
    weak var owner: TranscriptTableViewOwner?

    override func tile() {
        super.tile()
        // The document's height is decided here, and a height can move the end
        // of the scroll without the clip moving — a reload, a re-measure.
        owner?.tableViewDidTile(self)
    }

    override func layout() {
        super.layout()
        owner?.tableViewDidLayout(self)
    }

    /// Every press that selects: one on a row's text, passed up the chain by its
    /// `BlockView`, and one no row took — the margins beside the content, the gap
    /// between two rows, a host row that does not handle the mouse, which starts
    /// from the nearest position as a press in `NSTextView`'s margin does.
    ///
    /// `super` is not called: its tracking loop selects table rows, which the
    /// transcript never shows. The transcript's loop takes the gesture instead.
    override func mouseDown(with event: NSEvent) {
        owner?.tableView(self, trackSelectionFrom: event)
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        owner?.tableViewDidResignFirstResponder(self)
        return true
    }

    /// The key being interpreted, so one the transcript doesn't answer can go up
    /// the chain as itself.
    private var interpretedKey: NSEvent?

    /// Keys are interpreted, not switched on, so the reader's own key bindings
    /// apply. The transcript answers only the scrolling commands; every other key
    /// — typing, Return, Escape — goes to the next responder **as the event**, the
    /// way `NSResponder` passes a key it doesn't handle. That is the whole of what
    /// lets a host type into its input while the transcript has focus: its view
    /// controller is further up the chain, sees the key, and hands it on. The
    /// event rather than its text, so an input method there composes it.
    ///
    /// `super` is never asked: `NSTableView` would move a row selection the
    /// transcript never shows (↓ selected row 0 and scrolled to the top) and
    /// swallows Escape and Home.
    override func keyDown(with event: NSEvent) {
        interpretedKey = event
        defer { interpretedKey = nil }
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        if owner?.tableView(self, performScrollCommand: selector) == true { return }
        passInterpretedKeyUp()
    }

    override func insertText(_ insertString: Any) {
        passInterpretedKeyUp()
    }

    private func passInterpretedKeyUp() {
        guard let interpretedKey else { return }
        nextResponder?.keyDown(with: interpretedKey)
    }

    @objc func copy(_ sender: Any?) {
        owner?.tableViewCopySelection(self)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(copy(_:)) else { return super.validateUserInterfaceItem(item) }
        return owner?.tableViewCanCopySelection(self) ?? false
    }
}

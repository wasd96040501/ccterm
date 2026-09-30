import AppKit

/// How rows look, and what the list reports. `NSTableViewDelegate`'s half of
/// the split.
///
/// `heightOfRow` and `viewForRow` are required: every row is a host view with
/// an exact height. The rest have defaults.
@MainActor
public protocol ExactListViewDelegate: AnyObject {

    /// Row `row`'s exact height when laid out at `width`: finite and > 0
    /// (SPEC L12).
    ///
    /// Asked for **every** row, on screen or not (G2). Answer from the model,
    /// never by building a view. Asked again only when the row is inserted or
    /// noted (U5), or when `width` changes (§9), and never twice at the same
    /// width in between (W6).
    ///
    /// *Deviation from `tableView(_:heightOfRow:)`:* the `width`. A row's
    /// height depends on it, and the list measures at a width it has committed
    /// to, which during a layout pass can be ahead of `bounds` (W1). The value
    /// is never ≤ 0 (L7).
    func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat

    /// The view for a row that is joining the mounted set (P2), and for a
    /// mounted row being reloaded (U6), whose current view `makeView` hands
    /// back. `tableView(_:viewFor:row:)`, without the column.
    ///
    /// Recycle through `makeView(withIdentifier:make:)`, and bind every field:
    /// the instance may have been showing another row a moment ago. Don't set
    /// its frame; the list sizes it to `width × height`.
    func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView

    /// `view` has left the mounted set and is going back into the pool
    /// (P3). `tableView(_:didRemove:forRow:)`, including its −1 for a row that
    /// was removed (M10). Stop anything the view started on the row's behalf:
    /// timers, tasks, subscriptions.
    func listView(_ listView: ExactListView, didRemove view: NSView, forRow row: Int)

    /// `isFollowingTail` changed (A8): the moment to show or hide a "jump to
    /// latest" control. Changes only.
    func listView(_ listView: ExactListView, didChangeTailFollowing isFollowingTail: Bool)

    /// The offset changed (S5): the reader scrolled, a scroll request moved it,
    /// or a commit did. Called once the rows the new offset needs are mounted.
    /// The counterpart of observing an `NSScrollView`'s clip view bounds,
    /// which the list keeps private (L2).
    func listViewDidScroll(_ listView: ExactListView)

    /// A key binding's command while the list has focus, offered before the
    /// list scrolls by it (K1). Return `true` if handled. This is the same hook
    /// as `NSTextView`'s `textView(_:doCommandBy:)`.
    func listView(_ listView: ExactListView, doCommandBy selector: Selector) -> Bool
}

extension ExactListViewDelegate {

    public func listView(_ listView: ExactListView, didRemove view: NSView, forRow row: Int) {}

    public func listView(_ listView: ExactListView, didChangeTailFollowing isFollowingTail: Bool) {}

    public func listViewDidScroll(_ listView: ExactListView) {}

    public func listView(_ listView: ExactListView, doCommandBy selector: Selector) -> Bool {
        false
    }
}

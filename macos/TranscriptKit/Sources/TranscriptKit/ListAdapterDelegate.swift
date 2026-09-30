import AppKit

/// What `ListAdapter` asks of the transcript: the list's questions and reports,
/// answered on the transcript's terms — nothing here names `ExactListView`'s
/// protocols, which stay off the package's public surface.
@MainActor
protocol ListAdapterDelegate: AnyObject {

    /// The data source's current row count.
    func numberOfRows(in listAdapter: ListAdapter) -> Int

    /// Row `row`'s height when the list is `rowWidth` wide.
    func listAdapter(_ listAdapter: ListAdapter, heightOfRow row: Int, rowWidth: CGFloat) -> CGFloat

    /// The gap above row `row`, or `nil` for the transcript's own.
    func listAdapter(_ listAdapter: ListAdapter, customSpacingAboveRow row: Int) -> CGFloat?

    /// The cell for row `row`, arriving or being reloaded.
    func listAdapter(_ listAdapter: ListAdapter, viewForRow row: Int) -> NSView

    /// `view`, a cell, left row `row` (−1 for a removed row).
    func listAdapter(_ listAdapter: ListAdapter, didRemove view: NSView, forRow row: Int)

    /// Whether the list is following its tail changed.
    func listAdapter(_ listAdapter: ListAdapter, didChangeTailFollowing isFollowingTail: Bool)

    /// A key binding's command while the list has focus; `true` if handled.
    func listAdapter(_ listAdapter: ListAdapter, doCommandBy selector: Selector) -> Bool

    /// The list's offset changed.
    func listAdapterDidScroll(_ listAdapter: ListAdapter)
}

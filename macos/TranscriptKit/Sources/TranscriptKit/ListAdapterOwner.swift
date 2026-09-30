import AppKit

/// What `ListAdapter` asks of the transcript: the list's questions and reports,
/// answered on the transcript's terms — nothing here names `ExactListView`'s
/// protocols, which stay off the package's public surface.
@MainActor
protocol ListAdapterOwner: AnyObject {

    /// The data source's row count.
    var numberOfRowsInDataSource: Int { get }

    /// Row `row`'s height when the list is `rowWidth` wide.
    func height(ofRow row: Int, rowWidth: CGFloat) -> CGFloat

    /// The gap above row `row`, or `nil` for the transcript's own.
    func customSpacing(aboveRow row: Int) -> CGFloat?

    /// The cell for row `row`, arriving or being reloaded.
    func view(forRow row: Int) -> NSView

    /// `view`, a cell, left row `row` (−1 for a removed row).
    func didRemove(_ view: NSView, forRow row: Int)

    /// Whether the list is following its tail changed.
    func didChangeTailFollowing(_ isFollowingTail: Bool)

    /// A key binding's command while the list has focus; `true` if handled.
    func doCommand(by selector: Selector) -> Bool

    /// The list's offset changed.
    func didScroll()
}

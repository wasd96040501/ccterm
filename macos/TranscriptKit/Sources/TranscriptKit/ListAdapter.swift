import AppKit
import ExactList

/// `ExactListView`'s data source and delegate, forwarded to the transcript.
///
/// Not a conformance on `TranscriptView` itself: that type is public, so the
/// conformance would be too, putting the list's callbacks on the package's
/// surface next to the transcript's own near-identically named ones. Holds its
/// owner weakly — the transcript owns this, the list only refers to it.
@MainActor
final class ListAdapter: ExactListViewDataSource, ExactListViewDelegate {

    private weak var owner: ListAdapterOwner?

    init(owner: ListAdapterOwner) {
        self.owner = owner
    }

    func numberOfRows(in listView: ExactListView) -> Int {
        owner?.numberOfRowsInDataSource ?? 0
    }

    func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        owner?.height(ofRow: row, rowWidth: width) ?? 1
    }

    func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        owner?.view(forRow: row) ?? NSView()
    }

    func listView(_ listView: ExactListView, didRemove view: NSView, forRow row: Int) {
        owner?.didRemove(view, forRow: row)
    }

    func listView(_ listView: ExactListView, didChangeTailFollowing isFollowingTail: Bool) {
        owner?.didChangeTailFollowing(isFollowingTail)
    }

    func listView(_ listView: ExactListView, doCommandBy selector: Selector) -> Bool {
        owner?.doCommand(by: selector) ?? false
    }

    func listViewDidScroll(_ listView: ExactListView) {
        owner?.didScroll()
    }
}

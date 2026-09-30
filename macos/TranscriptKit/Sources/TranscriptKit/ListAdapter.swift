import AppKit
import ExactList

/// `ExactListView`'s data source and delegate, forwarded to the transcript.
///
/// Not a conformance on `TranscriptView` itself: that type is public, so the
/// conformance would be too, putting the list's callbacks on the package's
/// surface next to the transcript's own near-identically named ones. Holds its
/// delegate weakly — the transcript owns this, the list only refers to it.
@MainActor
final class ListAdapter: ExactListViewDataSource, ExactListViewDelegate {

    private weak var delegate: ListAdapterDelegate?

    init(delegate: ListAdapterDelegate) {
        self.delegate = delegate
    }

    func numberOfRows(in listView: ExactListView) -> Int {
        delegate?.numberOfRowsInDataSource ?? 0
    }

    func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        delegate?.height(ofRow: row, rowWidth: width) ?? 1
    }

    func listView(_ listView: ExactListView, customSpacingAboveRow row: Int) -> CGFloat? {
        delegate?.customSpacing(aboveRow: row)
    }

    func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        delegate?.view(forRow: row) ?? NSView()
    }

    func listView(_ listView: ExactListView, didRemove view: NSView, forRow row: Int) {
        delegate?.didRemove(view, forRow: row)
    }

    func listView(_ listView: ExactListView, didChangeTailFollowing isFollowingTail: Bool) {
        delegate?.didChangeTailFollowing(isFollowingTail)
    }

    func listView(_ listView: ExactListView, doCommandBy selector: Selector) -> Bool {
        delegate?.doCommand(by: selector) ?? false
    }

    func listViewDidScroll(_ listView: ExactListView) {
        delegate?.didScroll()
    }
}

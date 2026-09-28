import AppKit

/// `NSTableView`'s data source and delegate, forwarded to the transcript.
///
/// Not a conformance on `TranscriptView` itself: that type is public, so the
/// conformance would be too, putting AppKit's table callbacks on the package's
/// surface next to three near-identically named row-count methods. Holds its
/// owner weakly — the transcript owns this, the table only refers to it — and
/// through `TableViewAdapterOwner`, the four answers a table asks for and nothing
/// else.
@MainActor
final class TableViewAdapter: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private weak var owner: TableViewAdapterOwner?

    init(owner: TableViewAdapterOwner) {
        self.owner = owner
        super.init()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        owner?.numberOfRowsInDataSource ?? 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        owner?.height(ofRow: row) ?? 0
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        owner?.view(forRow: row)
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        owner?.didRemove(rowView, forRow: row)
    }
}

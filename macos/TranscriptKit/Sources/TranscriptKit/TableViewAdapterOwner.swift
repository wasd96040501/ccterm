import AppKit

/// What `TableViewAdapter` forwards the table's questions to: how many rows, how
/// tall each is, which view shows it, and that it left. The transcript answers.
@MainActor
protocol TableViewAdapterOwner: AnyObject {

    /// The data source's row count — asked by the table, which then caches it.
    var numberOfRowsInDataSource: Int { get }

    func height(ofRow row: Int) -> CGFloat

    func view(forRow row: Int) -> NSView?

    func didRemove(_ rowView: NSTableRowView, forRow row: Int)
}

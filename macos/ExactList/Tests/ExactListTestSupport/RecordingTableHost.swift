import AppKit

/// `RecordingHost`'s counterpart for a real, view-based, single-column
/// `NSTableView`: the other side of every characterization test and benchmark.
///
/// It answers from the same height function a `RecordingHost` would, so both
/// lists get identical workloads. `NSTableView` passes no width, so the host
/// reads the column's width at the moment of the call and logs it. That log is
/// what shows a table measuring before layout (SPEC §2).
@MainActor
public final class RecordingTableHost: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    public var count: Int

    public var height: (_ row: Int, _ width: CGFloat) -> CGFloat

    /// Every call, in order, with the column width the table had at that moment.
    public private(set) var calls: [HostCall] = []

    public init(count: Int, height: @escaping (_ row: Int, _ width: CGFloat) -> CGFloat) {
        self.count = count
        self.height = height
        super.init()
    }

    public func resetCalls() {
        calls.removeAll()
    }

    /// A single-column, view-based table with no header, no selection
    /// highlight, no intercell spacing and `usesAutomaticRowHeights` off,
    /// wired to this host. The configuration matches ExactList's, so the two
    /// are compared like for like.
    public func makeTableView() -> NSTableView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        return table
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        calls.append(.numberOfRows)
        return count
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = tableView.tableColumns.first?.width ?? 0
        calls.append(.heightOfRow(row, width: width))
        return height(row, width)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        calls.append(.viewForRow(row))
        if let view = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) {
            return view
        }
        let view = NSView()
        view.identifier = Self.cellIdentifier
        return view
    }

    public func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        calls.append(.didRemove(ObjectIdentifier(rowView), row: row))
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("RecordingTableHost.column")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("RecordingTableHost.cell")
}

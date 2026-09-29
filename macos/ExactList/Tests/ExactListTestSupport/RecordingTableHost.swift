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
        fatalError("unimplemented: test support")
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        fatalError("unimplemented: test support")
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        fatalError("unimplemented: test support")
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        fatalError("unimplemented: test support")
    }

    public func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        fatalError("unimplemented: test support")
    }
}

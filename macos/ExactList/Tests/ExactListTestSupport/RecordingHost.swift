import AppKit
import ExactList

/// A data source and delegate that the tests control, and that logs every call
/// (`calls`).
///
/// Heights come from `height(row, width)`, a function of the test's own model,
/// so the test can compute expected frames without asking the list. Views are
/// plain `NSView`s recycled under one identifier, tagged with the row they were
/// bound to.
@MainActor
public final class RecordingHost: ExactListViewDataSource, ExactListViewDelegate {

    /// The row count the data source answers. Tests change it together with the
    /// update they announce.
    public var count: Int

    /// The height function the delegate answers from.
    public var height: (_ row: Int, _ width: CGFloat) -> CGFloat

    /// Every call, in order.
    public private(set) var calls: [HostCall] = []

    /// Answer for `doCommandBy`: which selectors the host claims.
    public var handledCommands: Set<Selector> = []

    /// Run for each command before answering it, with the list.
    public var onCommand: ((ExactListView, Selector) -> Void)?

    private var bound: [ObjectIdentifier: Int] = [:]

    public init(count: Int, height: @escaping (_ row: Int, _ width: CGFloat) -> CGFloat) {
        self.count = count
        self.height = height
    }

    /// Forgets the log, for a test that asserts on what happens after a point.
    public func resetCalls() {
        calls.removeAll()
    }

    /// The row each live view was last bound to, by the view's identity.
    public func boundRow(of view: NSView) -> Int? {
        bound[ObjectIdentifier(view)]
    }

    public func numberOfRows(in listView: ExactListView) -> Int {
        calls.append(.numberOfRows)
        return count
    }

    public func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        calls.append(.heightOfRow(row, width: width))
        return height(row, width)
    }

    public func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        calls.append(.viewForRow(row))
        let view = listView.makeView(withIdentifier: Self.rowIdentifier) { NSView() }
        bound[ObjectIdentifier(view)] = row
        return view
    }

    public func listView(_ listView: ExactListView, didRemove view: NSView, forRow row: Int) {
        calls.append(.didRemove(ObjectIdentifier(view), row: row))
    }

    public func listView(_ listView: ExactListView, didChangeTailFollowing isFollowingTail: Bool) {
        calls.append(.didChangeTailFollowing(isFollowingTail))
    }

    public func listView(_ listView: ExactListView, doCommandBy selector: Selector) -> Bool {
        calls.append(.doCommand(selector))
        onCommand?(listView, selector)
        return handledCommands.contains(selector)
    }

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("RecordingHost.row")
}

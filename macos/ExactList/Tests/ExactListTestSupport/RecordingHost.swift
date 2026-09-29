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
        fatalError("unimplemented: test support")
    }

    public func numberOfRows(in listView: ExactListView) -> Int {
        fatalError("unimplemented: test support")
    }

    public func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        fatalError("unimplemented: test support")
    }

    public func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        fatalError("unimplemented: test support")
    }

    public func listView(_ listView: ExactListView, didRemove view: NSView, forRow row: Int) {
        fatalError("unimplemented: test support")
    }

    public func listView(_ listView: ExactListView, didChangeTailFollowing isFollowingTail: Bool) {
        fatalError("unimplemented: test support")
    }

    public func listView(_ listView: ExactListView, doCommandBy selector: Selector) -> Bool {
        fatalError("unimplemented: test support")
    }
}

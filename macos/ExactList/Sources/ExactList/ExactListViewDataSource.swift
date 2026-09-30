import AppKit

/// How many rows there are. `NSTableViewDataSource`'s half of the split: the
/// data source says *what*, the delegate says *how it looks*.
///
/// The host owns the data, and announces every change through the list's
/// update methods. The list never polls. The count is checked against those
/// announcements at every commit (SPEC L10).
@MainActor
public protocol ExactListViewDataSource: AnyObject {

    /// `NSTableViewDataSource.numberOfRows(in:)`.
    func numberOfRows(in listView: ExactListView) -> Int
}

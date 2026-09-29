import AppKit
import ExactListCore

extension ExactListView {

    /// The batch proxy (SPEC U3): the only way into a batch, and only for as
    /// long as its closure runs.
    ///
    /// It records; it doesn't apply. Each call follows `NSTableView`'s
    /// incremental index rules (U2). Heights and views are asked for once the
    /// closure has returned (U5).
    @MainActor
    public final class Updates {

        /// Starts recording against the `oldCount` rows the batch begins with,
        /// which is what every index is range-checked against (L12).
        init(oldCount: Int) {
            fatalError("unimplemented: SPEC U3")
        }

        /// The edits so far. Read by the list at commit.
        var map: RowIndexMap {
            fatalError("unimplemented: SPEC U3")
        }

        /// Closes the proxy once its closure has returned. Any later call stops
        /// with a precondition failure (U3).
        func close() {
            fatalError("unimplemented: SPEC U3")
        }

        /// `NSTableView.insertRows(at:withAnimation:)`.
        public func insertRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
            fatalError("unimplemented: SPEC U2")
        }

        /// `NSTableView.removeRows(at:withAnimation:)`.
        public func removeRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
            fatalError("unimplemented: SPEC U2")
        }

        /// `NSTableView.moveRow(at:to:)`.
        public func moveRow(at oldIndex: Int, to newIndex: Int) {
            fatalError("unimplemented: SPEC U2")
        }

        /// `NSTableView.reloadData(forRowIndexes:columnIndexes:)`, without the
        /// columns (U6).
        public func reloadData(forRowIndexes indexes: IndexSet) {
            fatalError("unimplemented: SPEC U6")
        }

        /// `NSTableView.noteHeightOfRows(withIndexesChanged:)` (U5).
        public func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
            fatalError("unimplemented: SPEC U5")
        }
    }
}

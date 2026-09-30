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

        private var recorded: RowIndexMap
        private var isOpen = true

        /// Starts recording against the `oldCount` rows the batch begins with,
        /// which is what every index is range-checked against (L12).
        init(oldCount: Int) {
            recorded = RowIndexMap(oldCount: oldCount)
        }

        /// The edits so far. Read by the list at commit.
        var map: RowIndexMap {
            recorded
        }

        /// Closes the proxy once its closure has returned. Any later call stops
        /// with a precondition failure (U3).
        func close() {
            isOpen = false
        }

        /// `NSTableView.insertRows(at:withAnimation:)`.
        public func insertRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
            record(.insert(indexes, RowTransition(rawValue: options.rawValue)))
        }

        /// `NSTableView.removeRows(at:withAnimation:)`.
        public func removeRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
            record(.remove(indexes, RowTransition(rawValue: options.rawValue)))
        }

        /// `NSTableView.moveRow(at:to:)`.
        public func moveRow(at oldIndex: Int, to newIndex: Int) {
            record(.move(from: oldIndex, to: newIndex))
        }

        /// `NSTableView.reloadData(forRowIndexes:columnIndexes:)`, without the
        /// columns (U6).
        public func reloadData(forRowIndexes indexes: IndexSet) {
            record(.reload(indexes))
        }

        /// `NSTableView.noteHeightOfRows(withIndexesChanged:)` (U5).
        public func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
            record(.noteHeight(indexes))
        }

        private func record(_ edit: RowEdit) {
            precondition(isOpen, "ExactList: a batch's Updates used after its closure returned (U3)")
            recorded.apply(edit)
        }
    }
}

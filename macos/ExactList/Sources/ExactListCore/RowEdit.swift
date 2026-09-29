import Foundation

/// One update, with `NSTableView`'s index rules (SPEC U2): each applies to the
/// rows as the preceding updates in the batch left them.
public enum RowEdit: Equatable, Sendable {

    /// `insertRows(at:withAnimation:)`. The indexes are in the numbering after
    /// the insert.
    case insert(IndexSet, RowTransition)

    /// `removeRows(at:withAnimation:)`. The indexes are in the numbering before
    /// the removal.
    case remove(IndexSet, RowTransition)

    /// `moveRow(at:to:)`: a removal followed by an insert, keeping the row's view.
    case move(from: Int, to: Int)

    /// `noteHeightOfRows(withIndexesChanged:)`: ask these rows for their height
    /// again at commit.
    case noteHeight(IndexSet)

    /// `reloadData(forRowIndexes:)`: ask these rows for their views again at
    /// commit (U6).
    case reload(IndexSet)
}

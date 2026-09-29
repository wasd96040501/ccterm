import Foundation

/// What a batch did to the row numbering: the old↔new index mapping, and which
/// rows need asking again at commit (SPEC U2, U5, U6).
///
/// Built one `RowEdit` at a time, in call order, which is `NSTableView`'s
/// incremental semantics. Each structural edit costs O(n) (G5).
public struct RowIndexMap: Equatable, Sendable {

    /// An identity map over `oldCount` rows: the start of every batch.
    public init(oldCount: Int) {
        fatalError("unimplemented: SPEC U2")
    }

    /// Rows before the batch.
    public var oldCount: Int {
        fatalError("unimplemented: SPEC U2")
    }

    /// Rows after the edits so far. This is what L10 checks the data source
    /// against.
    public var newCount: Int {
        fatalError("unimplemented: SPEC U2")
    }

    /// Applies one edit. Stops with a precondition failure on an index out of
    /// range (L12).
    public mutating func apply(_ edit: RowEdit) {
        fatalError("unimplemented: SPEC U2")
    }

    /// Where old row `row` ended up, or `nil` if it was removed.
    public func newIndex(forOld row: Int) -> Int? {
        fatalError("unimplemented: SPEC U2")
    }

    /// Which old row new row `row` was, or `nil` if it was inserted.
    public func oldIndex(forNew row: Int) -> Int? {
        fatalError("unimplemented: SPEC U2")
    }

    /// Inserted rows, in the new numbering, with the transition each was
    /// inserted with.
    public var insertions: [Int: RowTransition] {
        fatalError("unimplemented: SPEC U2")
    }

    /// Removed rows, in the old numbering, with the transition each was
    /// removed with.
    public var removals: [Int: RowTransition] {
        fatalError("unimplemented: SPEC U2")
    }

    /// Moved rows, in the new numbering (M10).
    public var movedRows: IndexSet {
        fatalError("unimplemented: SPEC U2")
    }

    /// Surviving rows whose height must be asked for again, in the new
    /// numbering (U5). Inserted rows are not included; they are always asked.
    public var notedRows: IndexSet {
        fatalError("unimplemented: SPEC U5")
    }

    /// Surviving rows whose view must be asked for again, in the new numbering
    /// (U6).
    public var reloadedRows: IndexSet {
        fatalError("unimplemented: SPEC U6")
    }

    /// Whether the batch changed anything at all. An empty batch commits
    /// nothing, and its completion handler still runs (U8).
    public var isEmpty: Bool {
        fatalError("unimplemented: SPEC U2")
    }
}

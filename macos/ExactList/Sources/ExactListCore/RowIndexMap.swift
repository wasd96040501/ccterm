import Foundation

/// What a batch did to the row numbering: the old↔new index mapping, and which
/// rows need asking again at commit (SPEC U2, U5, U6).
///
/// Built one `RowEdit` at a time, in call order, which is `NSTableView`'s
/// incremental semantics. Each structural edit costs O(n) (G5).
public struct RowIndexMap: Equatable, Sendable {

    /// One row in the current numbering.
    private struct Slot: Equatable, Sendable {
        /// The row's old index, or `nil` if the batch inserted it.
        var oldRow: Int?
        /// The transition it was inserted with.
        var transition: RowTransition = []
        var isMoved = false
        var isNoted = false
        var isReloaded = false
    }

    private let rowsBefore: Int

    private var slots: [Slot]

    /// Each old row's current index, or `nil` once removed.
    private var newIndexes: [Int?]

    private var removed: [Int: RowTransition] = [:]

    private var isEdited = false

    /// An identity map over `oldCount` rows: the start of every batch.
    public init(oldCount: Int) {
        precondition(oldCount >= 0, "ExactList: a row count can't be negative")
        rowsBefore = oldCount
        slots = (0..<oldCount).map { Slot(oldRow: $0) }
        newIndexes = Array(0..<oldCount)
    }

    /// Rows before the batch.
    public var oldCount: Int {
        rowsBefore
    }

    /// Rows after the edits so far. This is what L10 checks the data source
    /// against.
    public var newCount: Int {
        slots.count
    }

    /// Applies one edit. Stops with a precondition failure on an index out of
    /// range (L12).
    public mutating func apply(_ edit: RowEdit) {
        isEdited = true
        switch edit {
        case .insert(let rows, let transition):
            insert(rows, transition)
        case .remove(let rows, let transition):
            remove(rows, transition)
        case .move(let from, let to):
            precondition(
                slots.indices.contains(from), "ExactList: moveRow(at: \(from)) out of range 0..<\(newCount) (L12)")
            precondition(slots.indices.contains(to), "ExactList: moveRow(to: \(to)) out of range 0..<\(newCount) (L12)")
            var slot = slots.remove(at: from)
            if slot.oldRow != nil { slot.isMoved = true }
            slots.insert(slot, at: to)
            reindex()
        case .noteHeight(let rows):
            mark(rows) { $0.isNoted = true }
        case .reload(let rows):
            mark(rows) { $0.isReloaded = true }
        }
    }

    /// Where old row `row` ended up, or `nil` if it was removed.
    public func newIndex(forOld row: Int) -> Int? {
        precondition(newIndexes.indices.contains(row), "ExactList: old row \(row) out of range 0..<\(oldCount)")
        return newIndexes[row]
    }

    /// Which old row new row `row` was, or `nil` if it was inserted.
    public func oldIndex(forNew row: Int) -> Int? {
        precondition(slots.indices.contains(row), "ExactList: new row \(row) out of range 0..<\(newCount)")
        return slots[row].oldRow
    }

    /// Inserted rows, in the new numbering, with the transition each was
    /// inserted with.
    public var insertions: [Int: RowTransition] {
        var insertions: [Int: RowTransition] = [:]
        for (row, slot) in slots.enumerated() where slot.oldRow == nil {
            insertions[row] = slot.transition
        }
        return insertions
    }

    /// Removed rows, in the old numbering, with the transition each was
    /// removed with.
    public var removals: [Int: RowTransition] {
        removed
    }

    /// Moved rows, in the new numbering (M10).
    public var movedRows: IndexSet {
        rows { $0.isMoved }
    }

    /// Surviving rows whose height must be asked for again, in the new
    /// numbering (U5). Inserted rows are not included; they are always asked.
    public var notedRows: IndexSet {
        rows { $0.isNoted }
    }

    /// Surviving rows whose view must be asked for again, in the new numbering
    /// (U6).
    public var reloadedRows: IndexSet {
        rows { $0.isReloaded }
    }

    /// The batch as runs in the new order, covering every new row once (G5).
    var runs: [RowRun] {
        var runs: [RowRun] = []
        for (row, slot) in slots.enumerated() {
            guard let old = slot.oldRow else {
                if case .inserted(let new, let count, let transition) = runs.last, transition == slot.transition {
                    runs[runs.count - 1] = .inserted(new: new, count: count + 1, transition: transition)
                } else {
                    runs.append(.inserted(new: row, count: 1, transition: slot.transition))
                }
                continue
            }
            if slot.isMoved {
                runs.append(.moved(old: old, new: row))
            } else if case .kept(let start, let new, let count) = runs.last, start + count == old {
                runs[runs.count - 1] = .kept(old: start, new: new, count: count + 1)
            } else {
                runs.append(.kept(old: old, new: row, count: 1))
            }
        }
        return runs
    }

    /// Whether the batch inserted, removed or moved anything: whether any row
    /// changed its index.
    var isStructural: Bool {
        slots.count != rowsBefore || slots.enumerated().contains { $0.element.oldRow != $0.offset || $0.element.isMoved }
    }

    /// Whether the batch changed anything at all. An empty batch commits
    /// nothing, and its completion handler still runs (U8).
    public var isEmpty: Bool {
        !isEdited
    }

    /// U2: `rows` are in the numbering after the insert, so the rows between
    /// them keep their order and fill the gaps.
    private mutating func insert(_ rows: IndexSet, _ transition: RowTransition) {
        guard let last = rows.last else { return }
        precondition(
            rows.first! >= 0 && last < slots.count + rows.count,
            "ExactList: insertRows(at:) index \(last) out of range 0..<\(slots.count + rows.count) (L12)")
        var result: [Slot] = []
        result.reserveCapacity(slots.count + rows.count)
        var source = 0
        for range in rows.rangeView {
            let kept = range.lowerBound - result.count
            result += slots[source..<(source + kept)]
            source += kept
            result += repeatElement(Slot(oldRow: nil, transition: transition), count: range.count)
        }
        result += slots[source...]
        slots = result
        reindex()
    }

    /// U2: `rows` are in the numbering before the removal.
    private mutating func remove(_ rows: IndexSet, _ transition: RowTransition) {
        guard let last = rows.last else { return }
        precondition(
            rows.first! >= 0 && last < slots.count,
            "ExactList: removeRows(at:) index \(last) out of range 0..<\(slots.count) (L12)")
        var result: [Slot] = []
        result.reserveCapacity(slots.count - rows.count)
        var source = 0
        for range in rows.rangeView {
            result += slots[source..<range.lowerBound]
            for slot in slots[range] {
                if let oldRow = slot.oldRow { removed[oldRow] = transition }
            }
            source = range.upperBound
        }
        result += slots[source...]
        slots = result
        reindex()
    }

    /// Flags surviving rows; inserted rows are asked for everything anyway.
    private mutating func mark(_ rows: IndexSet, _ flag: (inout Slot) -> Void) {
        guard let last = rows.last else { return }
        precondition(
            rows.first! >= 0 && last < slots.count, "ExactList: row \(last) out of range 0..<\(slots.count) (L12)")
        for row in rows where slots[row].oldRow != nil {
            flag(&slots[row])
        }
    }

    private mutating func reindex() {
        newIndexes = Array(repeating: nil, count: rowsBefore)
        for (row, slot) in slots.enumerated() {
            if let oldRow = slot.oldRow { newIndexes[oldRow] = row }
        }
    }

    private func rows(where flagged: (Slot) -> Bool) -> IndexSet {
        var rows = IndexSet()
        for (row, slot) in slots.enumerated() where flagged(slot) {
            rows.insert(row)
        }
        return rows
    }
}

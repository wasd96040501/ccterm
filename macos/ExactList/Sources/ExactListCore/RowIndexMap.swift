import Foundation

/// What a batch did to the row numbering: the old↔new index mapping, and which
/// rows need asking again at commit (SPEC U2, U5, U6).
///
/// Built one `RowEdit` at a time, in call order, which is `NSTableView`'s
/// incremental semantics. The batch is kept as `RowRun`s, so an untouched
/// stretch of rows costs one entry however long it is: a structural edit is
/// O(e + r) for `e` runs and the `r` rows it names, and a lookup O(log e)
/// (G5).
public struct RowIndexMap: Equatable, Sendable {

    private let rowsBefore: Int

    /// The runs in new order, each starting where the previous one ends, with
    /// adjacent runs merged wherever they continue each other: two maps that
    /// number the rows the same way hold the same runs.
    private var batch: [RowRun]

    private var rowsAfter: Int

    /// The kept and moved runs as `(old, new, count)`, sorted by old row: the
    /// reverse lookup.
    private var byOld: [OldSpan]

    private var removed: [Int: RowTransition] = [:]

    /// Surviving or moved rows the batch noted or reloaded, by old index.
    private var noted = IndexSet()
    private var reloaded = IndexSet()

    private var isEdited = false

    private struct OldSpan: Equatable, Sendable {
        var old: Int
        var new: Int
        var count: Int
    }

    /// An identity map over `oldCount` rows: the start of every batch. O(1).
    public init(oldCount: Int) {
        precondition(oldCount >= 0, "ExactList: a row count can't be negative")
        rowsBefore = oldCount
        rowsAfter = oldCount
        batch = oldCount > 0 ? [.kept(old: 0, new: 0, count: oldCount)] : []
        byOld = oldCount > 0 ? [OldSpan(old: 0, new: 0, count: oldCount)] : []
    }

    /// Rows before the batch.
    public var oldCount: Int {
        rowsBefore
    }

    /// Rows after the edits so far. This is what L10 checks the data source
    /// against.
    public var newCount: Int {
        rowsAfter
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
                from >= 0 && from < rowsAfter, "ExactList: moveRow(at: \(from)) out of range 0..<\(newCount) (L12)")
            precondition(to >= 0 && to < rowsAfter, "ExactList: moveRow(to: \(to)) out of range 0..<\(newCount) (L12)")
            move(from, to)
        case .noteHeight(let rows):
            mark(rows) { $0.noted.insert($1) }
        case .reload(let rows):
            mark(rows) { $0.reloaded.insert($1) }
        }
    }

    /// Where old row `row` ended up, or `nil` if it was removed. O(log e).
    public func newIndex(forOld row: Int) -> Int? {
        precondition(row >= 0 && row < rowsBefore, "ExactList: old row \(row) out of range 0..<\(oldCount)")
        var low = 0
        var high = byOld.count
        while low < high {
            let mid = (low + high) / 2
            if byOld[mid].old + byOld[mid].count <= row { low = mid + 1 } else { high = mid }
        }
        guard low < byOld.count, byOld[low].old <= row else { return nil }
        return byOld[low].new + (row - byOld[low].old)
    }

    /// Which old row new row `row` was, or `nil` if it was inserted. O(log e).
    public func oldIndex(forNew row: Int) -> Int? {
        precondition(row >= 0 && row < rowsAfter, "ExactList: new row \(row) out of range 0..<\(newCount)")
        switch batch[run(containing: row)] {
        case .kept(let old, let new, _): return old + (row - new)
        case .moved(let old, _): return old
        case .inserted: return nil
        }
    }

    /// Inserted rows, in the new numbering, with the transition each was
    /// inserted with.
    public var insertions: [Int: RowTransition] {
        var insertions: [Int: RowTransition] = [:]
        for case .inserted(let new, let count, let transition) in batch {
            for row in new..<(new + count) { insertions[row] = transition }
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
        var rows = IndexSet()
        for case .moved(_, let new) in batch { rows.insert(new) }
        return rows
    }

    /// Surviving rows whose height must be asked for again, in the new
    /// numbering (U5). Inserted rows are not included; they are always asked.
    public var notedRows: IndexSet {
        renumbered(noted)
    }

    /// Surviving rows whose view must be asked for again, in the new numbering
    /// (U6).
    public var reloadedRows: IndexSet {
        renumbered(reloaded)
    }

    /// The batch as runs in the new order, covering every new row once (G5).
    var runs: [RowRun] {
        batch
    }

    /// Whether the batch inserted, removed or moved anything: whether any row
    /// changed its index.
    var isStructural: Bool {
        rowsAfter != rowsBefore || batch.count > 1 || batch.contains { if case .kept = $0 { false } else { true } }
    }

    /// Whether the batch changed anything at all. An empty batch commits
    /// nothing, and its completion handler still runs (U8).
    public var isEmpty: Bool {
        !isEdited
    }

    /// U2: `rows` are in the numbering after the insert, so the rows between
    /// them keep their order and fill the gaps.
    private mutating func insert(_ rows: IndexSet, _ transition: RowTransition) {
        guard let first = rows.first, let last = rows.last else { return }
        precondition(
            first >= 0 && last < rowsAfter + rows.count,
            "ExactList: insertRows(at:) index \(last) out of range 0..<\(rowsAfter + rows.count) (L12)")
        for range in rows.rangeView {
            let at = split(at: range.lowerBound)
            batch.insert(.inserted(new: range.lowerBound, count: range.count, transition: transition), at: at)
            shift(from: at + 1, by: range.count)
            rowsAfter += range.count
        }
        normalize()
    }

    /// U2: `rows` are in the numbering before the removal.
    private mutating func remove(_ rows: IndexSet, _ transition: RowTransition) {
        guard let first = rows.first, let last = rows.last else { return }
        precondition(
            first >= 0 && last < rowsAfter,
            "ExactList: removeRows(at:) index \(last) out of range 0..<\(rowsAfter) (L12)")
        for range in rows.rangeView.reversed() {
            // Lower first: a split shifts the indexes of the runs after it.
            let start = split(at: range.lowerBound)
            let end = split(at: range.upperBound)
            for run in batch[start..<end] {
                switch run {
                case .kept(let old, _, let count):
                    for row in old..<(old + count) { removed[row] = transition }
                    noted.remove(integersIn: old..<(old + count))
                    reloaded.remove(integersIn: old..<(old + count))
                case .moved(let old, _):
                    removed[old] = transition
                    noted.remove(old)
                    reloaded.remove(old)
                case .inserted:
                    break
                }
            }
            batch.removeSubrange(start..<end)
            shift(from: start, by: -range.count)
            rowsAfter -= range.count
        }
        normalize()
    }

    /// A move takes the row out and puts it back at `to`; a row that was there
    /// before the batch is moved from then on, even back to its own place.
    private mutating func move(_ from: Int, _ to: Int) {
        let start = split(at: from)
        _ = split(at: from + 1)
        var run = batch.remove(at: start)
        shift(from: start, by: -1)
        if case .kept(let old, _, _) = run { run = .moved(old: old, new: to) }
        run = Self.starting(run, at: to)
        rowsAfter -= 1
        let at = split(at: to)
        batch.insert(run, at: at)
        shift(from: at + 1, by: 1)
        rowsAfter += 1
        normalize()
    }

    /// Flags surviving and moved rows; inserted rows are asked for everything
    /// anyway.
    private mutating func mark(_ rows: IndexSet, _ flag: (inout RowIndexMap, Int) -> Void) {
        guard let first = rows.first, let last = rows.last else { return }
        precondition(first >= 0 && last < rowsAfter, "ExactList: row \(last) out of range 0..<\(rowsAfter) (L12)")
        for row in rows {
            if let old = oldIndex(forNew: row) { flag(&self, old) }
        }
    }

    /// The index of the run that holds new row `row`.
    private func run(containing row: Int) -> Int {
        var low = 0
        var high = batch.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if batch[mid].newStart <= row { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Splits runs so one starts at new row `row`, and returns its index
    /// (`batch.count` when `row` is the end).
    private mutating func split(at row: Int) -> Int {
        guard row < rowsAfter else { return batch.count }
        let index = run(containing: row)
        let run = batch[index]
        let offset = row - run.newStart
        guard offset > 0 else { return index }
        switch run {
        case .kept(let old, let new, let count):
            batch[index] = .kept(old: old, new: new, count: offset)
            batch.insert(.kept(old: old + offset, new: row, count: count - offset), at: index + 1)
        case .inserted(let new, let count, let transition):
            batch[index] = .inserted(new: new, count: offset, transition: transition)
            batch.insert(.inserted(new: row, count: count - offset, transition: transition), at: index + 1)
        case .moved:
            preconditionFailure("a moved run holds one row")
        }
        return index + 1
    }

    private mutating func shift(from index: Int, by delta: Int) {
        guard delta != 0 else { return }
        for i in index..<batch.count {
            batch[i] = Self.starting(batch[i], at: batch[i].newStart + delta)
        }
    }

    /// Merges runs that continue each other, and rebuilds the reverse lookup.
    private mutating func normalize() {
        var merged: [RowRun] = []
        merged.reserveCapacity(batch.count)
        for run in batch where run.count > 0 {
            switch (merged.last, run) {
            case (.kept(let old, let new, let count)?, .kept(let nextOld, _, let nextCount))
            where old + count == nextOld:
                merged[merged.count - 1] = .kept(old: old, new: new, count: count + nextCount)
            case (.inserted(let new, let count, let transition)?, .inserted(_, let nextCount, let nextTransition))
            where transition == nextTransition:
                merged[merged.count - 1] = .inserted(new: new, count: count + nextCount, transition: transition)
            default:
                merged.append(run)
            }
        }
        batch = merged
        byOld = batch.compactMap { run in
            switch run {
            case .kept(let old, let new, let count): OldSpan(old: old, new: new, count: count)
            case .moved(let old, let new): OldSpan(old: old, new: new, count: 1)
            case .inserted: nil
            }
        }
        .sorted { $0.old < $1.old }
    }

    private func renumbered(_ oldRows: IndexSet) -> IndexSet {
        var rows = IndexSet()
        for old in oldRows {
            if let new = newIndex(forOld: old) { rows.insert(new) }
        }
        return rows
    }

    /// `run`, starting at new row `row`.
    private static func starting(_ run: RowRun, at row: Int) -> RowRun {
        switch run {
        case .kept(let old, _, let count): .kept(old: old, new: row, count: count)
        case .moved(let old, _): .moved(old: old, new: row)
        case .inserted(_, let count, let transition): .inserted(new: row, count: count, transition: transition)
        }
    }
}

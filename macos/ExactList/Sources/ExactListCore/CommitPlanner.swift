import CoreGraphics
import Foundation

/// Plans a commit (SPEC §6, §7, §8.2): resolve the anchor against the old
/// geometry, carry it through the map, restore it against the new geometry,
/// then work out every mounted row's start and end, capped by M7.
///
/// A pure function, so the property tests drive it with random batches and
/// compare it against a reference that shares none of its code.
public enum CommitPlanner {

    public static func plan(_ input: CommitInput) -> CommitPlan {
        let old = input.oldHeights
        let new = input.newHeights
        let map = input.map

        var anchor =
            input.targetOffset.map { ScrollAnchor.offset($0) }
            ?? ScrollAnchor.resolve(
                input.anchoring, heights: old, viewport: input.oldViewport, followsTail: input.followsTail
            ).mapped(through: map, oldHeights: old, oldViewport: input.oldViewport)
        if input.rescalesAnchor, case .row(let row, _) = anchor, let was = map.oldIndex(forNew: row) {
            anchor = anchor.rescaled(fromHeight: old[was], toHeight: new[row])
        }
        var after = input.newViewport
        after.offset = anchor.restoredOffset(heights: new, viewport: after)

        // M7: the rows that could be seen move, and the largest distance among them.
        let preparedTop = after.insetTop - after.overscan
        let preparedBottom = after.height - after.insetBottom + after.overscan
        var motions = Self.motions(input, offset: after.offset, top: preparedTop, bottom: preparedBottom)
        if !input.animates {
            for i in motions.indices {
                motions[i].startTop = motions[i].endTop
                motions[i].startHeight = motions[i].endHeight
                motions[i].transition = []
            }
        }

        let reach = max(0, after.height - after.insetTop - after.insetBottom)
        let largest =
            motions.lazy.filter { Self.sweeps($0, preparedTop, preparedBottom) }
            .map { abs($0.startTop - $0.endTop) }.max() ?? 0
        var amplitude: CGFloat = 1
        if largest > reach {
            amplitude = reach / largest
            for i in motions.indices {
                motions[i].startTop = motions[i].endTop + amplitude * (motions[i].startTop - motions[i].endTop)
                motions[i].startHeight =
                    motions[i].endHeight + amplitude * (motions[i].startHeight - motions[i].endHeight)
            }
        }
        motions.removeAll { !Self.sweeps($0, preparedTop, preparedBottom) }

        return CommitPlan(
            heights: new, offset: after.offset, anchor: anchor, motions: motions, amplitude: amplitude,
            isFollowingTail: input.followsTail && after.isAtTail(contentHeight: new.contentHeight))
    }

    /// M2's start and end for every row that M7 could consider, before M7 and
    /// before the final filter by `P`: new rows by new index, then the removed
    /// rows that were mounted, by old index.
    ///
    /// Only rows whose sweep can meet `P` are worked out (G5). Surviving rows
    /// keep their order in both layouts, and so do their tops and bottoms, so
    /// the ones whose hull meets `P` are one contiguous stretch of them, found
    /// by searching each layout. Inserted, moved and removed rows are the
    /// batch's own, and each is worked out.
    private static func motions(
        _ input: CommitInput, offset: CGFloat, top: CGFloat, bottom: CGFloat
    ) -> [RowMotion] {
        let old = input.oldHeights
        let new = input.newHeights
        let map = input.map
        let oldOffset = input.oldViewport.offset
        let runs = map.runs

        func oldTop(_ row: Int) -> CGFloat { old.top(ofRow: row) - oldOffset }
        func newTop(_ row: Int) -> CGFloat { new.top(ofRow: row) - offset }

        // The survivors, run by run, in an order both layouts share.
        let kept = Survivors(runs: runs)
        var motions: [RowMotion] = []

        // The stretch of survivors whose hull meets P: from the first whose
        // bottom (start or end) is below P's top, to the last whose top (start
        // or end) is above P's bottom. Without animation the start is the end,
        // so the old layout doesn't widen it.
        var first = new.firstRow(endingBelow: top + offset).flatMap { kept.first(atOrAfterNew: $0) }
        var last = kept.last(atOrBeforeNew: rowsStarting(in: new, below: bottom + offset) - 1)
        if input.animates {
            if let fromOld = old.firstRow(endingBelow: top + oldOffset).flatMap({ kept.first(atOrAfterOld: $0) }) {
                first = min(first ?? fromOld, fromOld)
            }
            if let fromOld = kept.last(atOrBeforeOld: rowsStarting(in: old, below: bottom + oldOffset) - 1) {
                last = max(last ?? fromOld, fromOld)
            }
        }
        if let first, let last, first <= last {
            for run in kept.runs where run.new <= last && run.new + run.count > first {
                for row in max(first, run.new)...min(last, run.new + run.count - 1) {
                    let was = run.old + (row - run.new)
                    motions.append(
                        RowMotion(
                            kind: .surviving, row: row, startTop: oldTop(was), endTop: newTop(row),
                            startHeight: old[was], endHeight: new[row], transition: []))
                }
            }
        }

        // The removed rows, in old order, for the gap rules.
        let removed = map.removals.keys.sorted()

        for run in runs {
            switch run {
            case .kept:
                continue
            case .moved(let was, let row):
                motions.append(
                    RowMotion(
                        kind: .moved, row: row, startTop: oldTop(was), endTop: newTop(row), startHeight: old[was],
                        endHeight: new[row], transition: []))
            case .inserted(let start, let count, let transition):
                // The gap: the survivors on either side, in both numberings.
                let before = kept.last(atOrBeforeNew: start - 1)
                let after = kept.first(atOrAfterNew: start + count)
                let oldBefore = before.flatMap { map.oldIndex(forNew: $0) } ?? -1
                let oldAfter = after.flatMap { map.oldIndex(forNew: $0) } ?? map.oldCount
                let lastRemoved = Self.last(in: removed, above: oldBefore, below: oldAfter)
                // Where the gap's old contents end, and the opening below it:
                // the gap's first inserted row's spacing, within the room there was.
                var contentsEnd: CGFloat?
                if let lastRemoved {
                    contentsEnd = oldTop(lastRemoved) + old[lastRemoved]
                } else if before != nil {
                    contentsEnd = oldTop(oldBefore) + old[oldBefore]
                }
                let opening = contentsEnd.map { end in
                    let first = kept.firstInserted(in: runs, above: before ?? -1, below: after ?? map.newCount) ?? start
                    let room = after == nil ? CGFloat.infinity : oldTop(oldAfter) - end
                    return min(new.spacing(aboveRow: first), room)
                }
                for row in start..<(start + count) {
                    let endTop = newTop(row)
                    var startTop = endTop
                    if let contentsEnd, let opening {
                        startTop = contentsEnd + opening
                    } else if after != nil {
                        startTop = oldTop(oldAfter)
                    }
                    motions.append(
                        RowMotion(
                            kind: .inserted, row: row, startTop: startTop, endTop: endTop, startHeight: 0,
                            endHeight: new[row], transition: transition))
                }
            }
        }
        motions.sort { $0.row < $1.row }

        let removals = map.removals
        for row in input.mountedRows where row < map.oldCount {
            guard let transition = removals[row] else { continue }
            let startTop = oldTop(row)
            let before = kept.last(atOrBeforeOld: row - 1)
            let after = kept.first(atOrAfterOld: row + 1)
            let firstInserted = kept.firstInserted(in: runs, above: before ?? -1, below: after ?? map.newCount)
            var endTop = startTop
            if let firstInserted {
                endTop = newTop(firstInserted)
            } else if let before {
                // The closing: the gap's first removed row's spacing, within
                // the room there is.
                let end = newTop(before) + new[before]
                let oldBefore = map.oldIndex(forNew: before) ?? -1
                let oldAfter = after.flatMap { map.oldIndex(forNew: $0) } ?? map.oldCount
                let first = Self.first(in: removed, above: oldBefore, below: oldAfter) ?? row
                let room = after.map { newTop($0) - end } ?? .infinity
                endTop = end + min(old.spacing(aboveRow: first), room)
            } else if let after {
                endTop = newTop(after)
            }
            motions.append(
                RowMotion(
                    kind: .removed, row: row, startTop: startTop, endTop: endTop, startHeight: old[row],
                    endHeight: 0, transition: transition))
        }
        return motions
    }

    /// How many rows of `heights` start above document `y`.
    private static func rowsStarting(in heights: RowHeights, below y: CGFloat) -> Int {
        heights.rows(intersecting: -.infinity, y).upperBound
    }

    /// The smallest of the sorted `rows` strictly between `lower` and `upper`.
    private static func first(in rows: [Int], above lower: Int, below upper: Int) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid] <= lower { low = mid + 1 } else { high = mid }
        }
        guard low < rows.count, rows[low] < upper else { return nil }
        return rows[low]
    }

    /// The largest of the sorted `rows` strictly between `lower` and `upper`.
    private static func last(in rows: [Int], above lower: Int, below upper: Int) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid] < upper { low = mid + 1 } else { high = mid }
        }
        guard low > 0, rows[low - 1] > lower else { return nil }
        return rows[low - 1]
    }

    /// The kept runs of a batch, which are in the same order by old row as by
    /// new row, so either numbering can be searched.
    private struct Survivors {

        let runs: [(old: Int, new: Int, count: Int)]

        init(runs: [RowRun]) {
            self.runs = runs.compactMap {
                guard case .kept(let old, let new, let count) = $0 else { return nil }
                return (old, new, count)
            }
        }

        /// The first surviving row at or after new row `row`, by new index.
        func first(atOrAfterNew row: Int) -> Int? {
            let index = firstRun { $0.new + $0.count > row }
            guard index < runs.count else { return nil }
            return max(row, runs[index].new)
        }

        /// The last surviving row at or before new row `row`, by new index.
        func last(atOrBeforeNew row: Int) -> Int? {
            let index = firstRun { $0.new > row } - 1
            guard index >= 0 else { return nil }
            return min(row, runs[index].new + runs[index].count - 1)
        }

        /// The first surviving row at or after old row `row`, by new index.
        func first(atOrAfterOld row: Int) -> Int? {
            let index = firstRun { $0.old + $0.count > row }
            guard index < runs.count else { return nil }
            let run = runs[index]
            return run.new + max(0, row - run.old)
        }

        /// The last surviving row at or before old row `row`, by new index.
        func last(atOrBeforeOld row: Int) -> Int? {
            let index = firstRun { $0.old > row } - 1
            guard index >= 0 else { return nil }
            let run = runs[index]
            return run.new + min(run.count - 1, row - run.old)
        }

        /// The first inserted row strictly between new rows `lower` and `upper`.
        func firstInserted(in all: [RowRun], above lower: Int, below upper: Int) -> Int? {
            var low = 0
            var high = all.count
            while low < high {
                let mid = (low + high) / 2
                if all[mid].newStart + all[mid].count <= lower + 1 { low = mid + 1 } else { high = mid }
            }
            for run in all[low...] {
                guard run.newStart < upper else { return nil }
                if case .inserted(let start, let count, _) = run, start + count > lower + 1 {
                    let row = max(start, lower + 1)
                    return row < upper ? row : nil
                }
            }
            return nil
        }

        /// The index of the first run for which `isPast` holds; `isPast` must
        /// hold for a suffix of the runs.
        private func firstRun(where isPast: ((old: Int, new: Int, count: Int)) -> Bool) -> Int {
            var low = 0
            var high = runs.count
            while low < high {
                let mid = (low + high) / 2
                if isPast(runs[mid]) { high = mid } else { low = mid + 1 }
            }
            return low
        }
    }

    /// Whether the hull of a motion's start and end screen intervals meets
    /// `P`, given in screen coordinates.
    private static func sweeps(_ motion: RowMotion, _ top: CGFloat, _ bottom: CGFloat) -> Bool {
        let lower = min(motion.startTop, motion.endTop)
        let upper = max(motion.startTop + motion.startHeight, motion.endTop + motion.endHeight)
        return lower < bottom && upper > top
    }
}

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

        var motions = Self.motions(input, offset: after.offset)
        if !input.animates {
            for i in motions.indices {
                motions[i].startTop = motions[i].endTop
                motions[i].startHeight = motions[i].endHeight
                motions[i].transition = []
            }
        }

        // M7: the rows that could be seen move, and the largest distance among them.
        let preparedTop = after.insetTop - after.overscan
        let preparedBottom = after.height - after.insetBottom + after.overscan
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

    /// M2's start and end for every row, before M7 and before filtering by `P`:
    /// new rows by new index, then the removed rows that were mounted, by old
    /// index.
    private static func motions(_ input: CommitInput, offset: CGFloat) -> [RowMotion] {
        let old = input.oldHeights
        let new = input.newHeights
        let map = input.map
        let oldOffset = input.oldViewport.offset
        let spacing = new.spacing
        let moved = map.movedRows
        let insertions = map.insertions

        // "Nearest surviving row" skips inserted, removed and moved rows.
        let survivesNew = (0..<map.newCount).map { map.oldIndex(forNew: $0) != nil && !moved.contains($0) }
        let survivesOld = (0..<map.oldCount).map { row in
            map.newIndex(forOld: row).map { !moved.contains($0) } ?? false
        }
        let before = nearest(survivesNew, ascending: true)
        let after = nearest(survivesNew, ascending: false)
        let beforeOld = nearest(survivesOld, ascending: true)
        let afterOld = nearest(survivesOld, ascending: false)

        func oldTop(_ row: Int) -> CGFloat { old.top(ofRow: row) - oldOffset }
        func newTop(_ row: Int) -> CGFloat { new.top(ofRow: row) - offset }

        var motions: [RowMotion] = []
        motions.reserveCapacity(map.newCount)
        for row in 0..<map.newCount {
            let endTop = newTop(row)
            let endHeight = new[row]
            if let was = map.oldIndex(forNew: row) {
                motions.append(
                    RowMotion(
                        kind: moved.contains(row) ? .moved : .surviving, row: row, startTop: oldTop(was),
                        endTop: endTop, startHeight: old[was], endHeight: endHeight, transition: []))
                continue
            }
            var startTop = endTop
            if let neighbour = before[row], let was = map.oldIndex(forNew: neighbour) {
                startTop = oldTop(was) + old[was] + spacing
            } else if let neighbour = after[row], let was = map.oldIndex(forNew: neighbour) {
                startTop = oldTop(was)
            }
            motions.append(
                RowMotion(
                    kind: .inserted, row: row, startTop: startTop, endTop: endTop, startHeight: 0,
                    endHeight: endHeight, transition: insertions[row] ?? []))
        }
        for (row, transition) in map.removals.sorted(by: { $0.key < $1.key })
        where input.mountedRows.contains(row) {
            let startTop = oldTop(row)
            var endTop = startTop
            if let neighbour = beforeOld[row], let now = map.newIndex(forOld: neighbour) {
                endTop = newTop(now) + new[now] + spacing
            } else if let neighbour = afterOld[row], let now = map.newIndex(forOld: neighbour) {
                endTop = newTop(now)
            }
            motions.append(
                RowMotion(
                    kind: .removed, row: row, startTop: startTop, endTop: endTop, startHeight: old[row],
                    endHeight: 0, transition: transition))
        }
        return motions
    }

    /// For each index, the nearest other index strictly before it (or after
    /// it, when not `ascending`) where `flags` is true.
    private static func nearest(_ flags: [Bool], ascending: Bool) -> [Int?] {
        var result = [Int?](repeating: nil, count: flags.count)
        var last: Int?
        let order = ascending ? Array(flags.indices) : flags.indices.reversed()
        for i in order {
            result[i] = last
            if flags[i] { last = i }
        }
        return result
    }

    /// Whether the hull of a motion's start and end screen intervals meets
    /// `P`, given in screen coordinates.
    private static func sweeps(_ motion: RowMotion, _ top: CGFloat, _ bottom: CGFloat) -> Bool {
        let lower = min(motion.startTop, motion.endTop)
        let upper = max(motion.startTop + motion.startHeight, motion.endTop + motion.endHeight)
        return lower < bottom && upper > top
    }
}

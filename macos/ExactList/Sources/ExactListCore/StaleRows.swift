import Foundation

/// The rows whose height was measured at a width other than the current one,
/// and the order in which they get refreshed (SPEC §9).
public struct StaleRows: Equatable, Sendable {

    private var count: Int

    private var stale = IndexSet()

    /// No stale rows, over `count` rows.
    public init(count: Int) {
        precondition(count >= 0, "ExactList: a row count can't be negative")
        self.count = count
    }

    public var isEmpty: Bool {
        stale.isEmpty
    }

    public func contains(_ row: Int) -> Bool {
        stale.contains(row)
    }

    /// W3: a width change makes every row stale except `fresh`, the rows just
    /// measured at the new width.
    public mutating func markAllStale(except fresh: IndexSet) {
        stale = IndexSet(integersIn: 0..<count).subtracting(fresh)
    }

    /// Rows measured at the current width.
    public mutating func markFresh(_ rows: IndexSet) {
        stale.subtract(rows)
    }

    /// Renumbers through a batch. Inserted rows arrive fresh (U5) and removed
    /// rows drop out.
    public mutating func apply(_ map: RowIndexMap) {
        precondition(map.oldCount == count, "ExactList: a map over \(map.oldCount) rows applied to \(count)")
        guard map.isStructural else { return }
        // Run by run, so a list that is all stale after a width change costs
        // O(runs), not O(n) (G5).
        var renumbered = IndexSet()
        for run in map.runs {
            switch run {
            case .kept(let old, let new, let count):
                var kept = stale.intersection(IndexSet(integersIn: old..<(old + count)))
                kept.shift(startingAt: 0, by: new - old)
                renumbered.formUnion(kept)
            case .moved(let old, let new):
                if stale.contains(old) { renumbered.insert(new) }
            case .inserted:
                break
            }
        }
        stale = renumbered
        count = map.newCount
    }

    /// W5: up to `limit` stale rows, nearest to `anchor` first, alternating
    /// down and up.
    public func refreshOrder(around anchor: Int, limit: Int) -> [Int] {
        var order: [Int] = []
        guard limit > 0 else { return order }
        if stale.contains(anchor) { order.append(anchor) }
        // IndexSet's searches are unreliable for negative integers.
        var down = anchor < 0 ? stale.first : stale.integerGreaterThan(anchor)
        var up = anchor > 0 ? stale.integerLessThan(anchor) : nil
        while order.count < limit {
            // At equal distance, down (the higher index) goes first.
            if let below = down, up.map({ below - anchor <= anchor - $0 }) ?? true {
                order.append(below)
                down = stale.integerGreaterThan(below)
            } else if let above = up {
                order.append(above)
                up = stale.integerLessThan(above)
            } else {
                break
            }
        }
        return order
    }
}

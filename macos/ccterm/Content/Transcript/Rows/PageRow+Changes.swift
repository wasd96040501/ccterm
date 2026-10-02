import Foundation

extension PageRow {
    /// What turns one list of rows into another, as a `TranscriptView`
    /// batch takes it: rows by identity (`id`) — gone, new, or there in both
    /// but no longer equal.
    ///
    /// Announce it in this order inside one `performBatchUpdates`: `removed`,
    /// then `inserted`, then `reloaded`. A batch applies its calls
    /// incrementally (ExactList U2), so each set is in the numbering the
    /// calls before it leave — which is why `reloaded`, last, is in the new
    /// list's.
    struct Changes: Equatable {
        /// Indexes in the old list: one `removeRows` call, pre-removal numbering.
        var removed = IndexSet()
        /// Indexes in the new list: one `insertRows` call, post-insert numbering.
        var inserted = IndexSet()
        /// Indexes in the new list of rows in both lists whose value changed:
        /// one `reloadRows` call, after the other two.
        var reloaded = IndexSet()

        var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && reloaded.isEmpty }
    }

    /// The changes from `old` to `new`. A live session's pages mostly append,
    /// and grow or settle their last rows; identities keep their order. A row
    /// that does change its place among the others is removed and inserted
    /// again, so the batch is right for any two lists.
    static func changes(from old: [PageRow], to new: [PageRow]) -> Changes {
        var oldIndex: [ID: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        for (index, row) in old.enumerated() { oldIndex[row.id] = index }

        // The rows in both lists, as (old index, new index) in new order; the
        // longest run of them that also keeps its old order stays put.
        var shared: [(old: Int, new: Int)] = []
        for (index, row) in new.enumerated() {
            if let was = oldIndex[row.id] { shared.append((was, index)) }
        }
        let kept = longestIncreasing(shared.map(\.old))

        var changes = Changes()
        var keptOld = IndexSet()
        var keptNew = IndexSet()
        for position in kept {
            let (was, now) = shared[position]
            keptOld.insert(was)
            keptNew.insert(now)
            if old[was] != new[now] { changes.reloaded.insert(now) }
        }
        changes.removed = IndexSet(integersIn: 0..<old.count).subtracting(keptOld)
        changes.inserted = IndexSet(integersIn: 0..<new.count).subtracting(keptNew)
        return changes
    }

    /// The positions in `values` (distinct) of a longest strictly increasing
    /// subsequence, in order. Patience sorting, O(n log n).
    private static func longestIncreasing(_ values: [Int]) -> [Int] {
        var tails: [Int] = []  // position of the smallest tail value per length
        var previous = [Int?](repeating: nil, count: values.count)
        for (position, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[position] = tails[low - 1] }
            if low == tails.count { tails.append(position) } else { tails[low] = position }
        }
        var result: [Int] = []
        var cursor = tails.last
        while let position = cursor {
            result.append(position)
            cursor = previous[position]
        }
        return result.reversed()
    }
}

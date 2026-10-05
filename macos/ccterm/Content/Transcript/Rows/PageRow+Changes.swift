import Foundation

extension PageRow {
    /// What turns one list of rows into another, as a `TranscriptView`
    /// batch takes it: rows by identity (`id`) — gone, new, moved, or there in
    /// both but no longer equal.
    ///
    /// Announce it in this order inside one `performBatchUpdates`: `removed`,
    /// then `moved`, then `inserted`, then `reloaded`. A batch applies its calls
    /// incrementally (ExactList U2), so each set is in the numbering the
    /// calls before it leave: after the removals and the moves the rows that
    /// stay are in the new list's order, which is why `inserted` and
    /// everything after it is in the new list's.
    struct Changes: Equatable {
        /// A row that slides: one `moveRow(at:to:)` call.
        struct Move: Equatable {
            var from: Int
            var to: Int
        }

        /// Indexes in the old list of rows the new list lacks: one `removeRows`
        /// call, pre-removal numbering.
        var removed = IndexSet()
        /// Rows in both lists that changed their place among the others, one
        /// `moveRow` call each, in order: `from` is where the row is after the
        /// removals and the moves before it, `to` where it is after its own.
        var moved: [Move] = []
        /// Indexes in the new list: one `insertRows` call, post-insert numbering.
        var inserted = IndexSet()
        /// Indexes in the new list of rows in both lists whose value changed:
        /// one `reloadRows` call, after the others.
        var reloaded = IndexSet()
        /// Indexes in the new list of rows in both lists, not reloaded, with
        /// another row above them now: their gap (`spacingAbove(after:)`)
        /// depends on it — one `noteHeightOfRows`, last.
        var regapped = IndexSet()

        var isEmpty: Bool {
            removed.isEmpty && moved.isEmpty && inserted.isEmpty && reloaded.isEmpty && regapped.isEmpty
        }
    }

    /// The changes from `old` to `new`. A live session's pages mostly append,
    /// and grow or settle their last rows; identities keep their order. A row
    /// that does change its place among the others — a queued prompt the CLI
    /// takes into the running turn — is moved, so the batch is right for any
    /// two lists.
    static func changes(from old: [PageRow], to new: [PageRow]) -> Changes {
        var oldIndex: [ID: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        for (index, row) in old.enumerated() { oldIndex[row.id] = index }

        // The rows in both lists, as (old index, new index) in new order; the
        // longest run of them that also keeps its old order stays put, the
        // rest move.
        var shared: [(old: Int, new: Int)] = []
        for (index, row) in new.enumerated() {
            if let was = oldIndex[row.id] { shared.append((was, index)) }
        }
        let kept = Set(longestIncreasing(shared.map(\.old)).map { shared[$0].new })

        var changes = Changes()
        var sharedOld = IndexSet()
        var sharedNew = IndexSet()
        for (was, now) in shared {
            sharedOld.insert(was)
            sharedNew.insert(now)
            if old[was] != new[now] {
                changes.reloaded.insert(now)
            } else {
                let above = now > 0 ? new[now - 1].id : nil
                let wasAbove = was > 0 ? old[was - 1].id : nil
                if above != wasAbove { changes.regapped.insert(now) }
            }
        }
        changes.removed = IndexSet(integersIn: 0..<old.count).subtracting(sharedOld)
        changes.inserted = IndexSet(integersIn: 0..<new.count).subtracting(sharedNew)

        // The rows that move go in order of where they land, each right after
        // the row that precedes it in the new list — which by then is placed.
        if kept.count < shared.count {
            var working = old.indices.filter { sharedOld.contains($0) }.map { old[$0].id }
            var previous: ID?
            for (_, now) in shared {
                defer { previous = new[now].id }
                guard !kept.contains(now) else { continue }
                let id = new[now].id
                guard let from = working.firstIndex(of: id) else { continue }
                working.remove(at: from)
                let to = previous.flatMap { working.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                working.insert(id, at: to)
                changes.moved.append(Changes.Move(from: from, to: to))
            }
        }
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

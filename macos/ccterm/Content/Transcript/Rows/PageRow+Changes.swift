import Foundation

extension PageRow {
    /// What turns one list of rows into another, as a `TranscriptView`
    /// batch takes it: rows by identity (`id`) — gone, new, or there in both
    /// but no longer equal.
    struct Changes: Equatable {
        /// Indexes in the old list.
        var removed = IndexSet()
        /// Indexes in the new list.
        var inserted = IndexSet()
        /// Indexes in the new list of rows in both lists whose value changed.
        var reloaded = IndexSet()

        var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && reloaded.isEmpty }
    }

    /// The changes from `old` to `new`. A live session's pages mostly append,
    /// and grow or settle their last rows; identities keep their order.
    static func changes(from old: [PageRow], to new: [PageRow]) -> Changes {
        // TODO(live): diff by `id`, then compare the rows in both.
        Changes()
    }
}

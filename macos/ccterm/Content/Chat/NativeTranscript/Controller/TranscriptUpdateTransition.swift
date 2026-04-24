import AppKit

/// `[ComponentRow]` 的差量变更描述。对齐 Telegram `TableUpdateTransition`。
///
/// - `deleted`:旧列表中被移除的下标,降序应用避免下标失效。
/// - `inserted`:新列表中插入的下标 + 新 row。升序应用。
/// - `updated`:新列表中 stableId 不变但 contentHash 变了的位置 + 新 row。
/// - `finalRows`:apply 完成后 controller 应持有的 row 列表。carry-over
///   的 row 保留旧值(state / layout 延续)。
struct TranscriptUpdateTransition {
    let deleted: [Int]
    let inserted: [(Int, ComponentRow)]
    let updated: [(Int, ComponentRow)]
    let finalRows: [ComponentRow]
    let animated: Bool

    var isEmpty: Bool {
        deleted.isEmpty && inserted.isEmpty && updated.isEmpty
    }

    static func empty(finalRows: [ComponentRow]) -> TranscriptUpdateTransition {
        TranscriptUpdateTransition(
            deleted: [], inserted: [], updated: [],
            finalRows: finalRows, animated: false)
    }
}

// MARK: - Diff

enum TranscriptDiff {

    /// 按 `stableId` 匹配新旧两个 row 列表,产出增量 transition。
    ///
    /// - 旧有 / 新无 → `deleted`
    /// - 旧无 / 新有 → `inserted`
    /// - 同 stableId:`contentHash` 等 → carry-over(保留旧 row),不等 → `updated`
    ///
    /// 不处理 move —— 聊天 99% 是尾部追加,偶发 reorder 退化成 delete+insert。
    @MainActor
    static func compute(
        old: [ComponentRow],
        new: [ComponentRow],
        animated: Bool
    ) -> TranscriptUpdateTransition {
        var oldIndexByStable: [StableId: Int] = [:]
        oldIndexByStable.reserveCapacity(old.count)
        for (i, row) in old.enumerated() { oldIndexByStable[row.stableId] = i }

        let newStableSet: Set<StableId> = Set(new.map { $0.stableId })

        var deleted: [Int] = []
        deleted.reserveCapacity(old.count)
        for (i, row) in old.enumerated() {
            if !newStableSet.contains(row.stableId) {
                deleted.append(i)
            }
        }

        var inserted: [(Int, ComponentRow)] = []
        var updated: [(Int, ComponentRow)] = []
        var finalRows: [ComponentRow] = []
        finalRows.reserveCapacity(new.count)

        for (i, newRow) in new.enumerated() {
            if let oldIdx = oldIndexByStable[newRow.stableId] {
                let oldRow = old[oldIdx]
                if oldRow.contentHash == newRow.contentHash {
                    // Carry-over:保留旧 row(含 state、layout 缓存)。
                    finalRows.append(oldRow)
                } else {
                    updated.append((i, newRow))
                    finalRows.append(newRow)
                }
            } else {
                inserted.append((i, newRow))
                finalRows.append(newRow)
            }
        }

        return TranscriptUpdateTransition(
            deleted: deleted,
            inserted: inserted,
            updated: updated,
            finalRows: finalRows,
            animated: animated)
    }
}

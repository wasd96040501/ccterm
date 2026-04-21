import AppKit

/// 对齐 Telegram `TableUpdateTransition`：一次差量变更的不可变描述。
///
/// ## 约定（和 Telegram 保持一致）
/// - `deleted`：**旧**列表中被移除的下标。`apply` 时按**降序**倒着 remove，
///   这样前面一个 remove 不会让后面的下标失效。
/// - `inserted`：**新**列表中插入的下标 + 新 row 对象。`apply` 时按**升序**
///   顺次 insert。注意顺序：先做完所有 delete、再做所有 insert。
/// - `updated`：**新**列表中 stableId 不变但 contentHash 变了的位置 + 新 row
///   对象。`apply` 调 `reloadRow(at:)`——若 rowView 还是同 class，走原地 set；
///   否则 remove+insert 同 index。
/// - `finalRows`：apply 完成后 controller 应持有的 row 列表。carry-over
///   的 row 保留旧对象（因此 `cachedHeight` / `cachedWidth` 延续）。
struct TranscriptUpdateTransition {
    let deleted: [Int]
    let inserted: [(Int, TranscriptRow)]
    let updated: [(Int, TranscriptRow)]
    let finalRows: [TranscriptRow]
    let animated: Bool

    var isEmpty: Bool {
        deleted.isEmpty && inserted.isEmpty && updated.isEmpty
    }

    /// 空 transition —— rows 完全等价时的结果。
    static func empty(finalRows: [TranscriptRow]) -> TranscriptUpdateTransition {
        TranscriptUpdateTransition(
            deleted: [],
            inserted: [],
            updated: [],
            finalRows: finalRows,
            animated: false)
    }
}

// MARK: - Diff

enum TranscriptDiff {

    /// 按 `stableId` 匹配新旧两个 row 列表，产出增量 transition。
    ///
    /// 策略（简单但对聊天 append-only 场景最优）：
    /// - 旧有 / 新无 → `deleted`（记旧下标）
    /// - 旧无 / 新有 → `inserted`（记新下标 + new row）
    /// - 同 stableId：
    ///   - `contentHash` 相同 → carry-over 旧 row（保留 layout 缓存）
    ///   - `contentHash` 不同 → `updated`（记新下标 + new row）
    ///
    /// 不处理 move —— 聊天 transcript 99% 是尾部追加，偶发的 reorder 会退化
    /// 成 delete+insert，视觉正确即可。后续真有需要再引入 LCS。
    @MainActor
    static func compute(
        old: [TranscriptRow],
        new: [TranscriptRow],
        animated: Bool
    ) -> TranscriptUpdateTransition {
        // 1) 建 stableId 索引。
        var oldIndexByStable: [AnyHashable: Int] = [:]
        oldIndexByStable.reserveCapacity(old.count)
        for (i, row) in old.enumerated() { oldIndexByStable[row.stableId] = i }

        let newStableSet: Set<AnyHashable> = Set(new.map { $0.stableId })

        // 2) deleted = 旧列表里 stableId 不在新集合的下标。
        var deleted: [Int] = []
        deleted.reserveCapacity(old.count)
        for (i, row) in old.enumerated() {
            if !newStableSet.contains(row.stableId) {
                deleted.append(i)
            }
        }

        // 3) 遍历新列表：决定每个位置是 carry-over / update / insert。
        var inserted: [(Int, TranscriptRow)] = []
        var updated: [(Int, TranscriptRow)] = []
        var finalRows: [TranscriptRow] = []
        finalRows.reserveCapacity(new.count)

        for (i, newRow) in new.enumerated() {
            if let oldIdx = oldIndexByStable[newRow.stableId] {
                let oldRow = old[oldIdx]
                if oldRow.contentHash == newRow.contentHash {
                    // Carry over：保留旧 row 对象（含 layout cache）。
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

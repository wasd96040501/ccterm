import AppKit

/// 持有 `[TranscriptRow]`，实现 `NSTableViewDataSource` / `NSTableViewDelegate`。
///
/// 对齐 Telegram `TableView`：不用整体 reloadData，改走 **增量 transition**：
/// - `setEntries` → diff → `merge(with: transition)` → `insertRows` / `removeRows` /
///   per-row `reloadData(row:)`。同 stableId 且内容未变的 row 直接 carry-over，
///   保留已经算好的 `cachedHeight` / layout。
/// - `tableWidthChanged` → 逐 row `makeSize`，**只**对 height 实际变化的 row 调
///   `noteHeightOfRows`；同时保存 / 还原 scroll anchor，避免拖拽 resize 时可视
///   区域漂移。
/// - row 侧可以通过 `table.noteHeightOfRow(_:)` / `table.reloadRow(_:)` 反向触发
///   单行刷新（=未来 tool block 展开 / 收起的入口）。
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var tableView: TranscriptTableView?
    private(set) var rows: [TranscriptRow] = []

    var theme: MarkdownTheme?
    var syntaxEngine: SyntaxHighlightEngine?

    /// 上次排版时使用的宽度。宽度真正变化才重算。
    private var lastLayoutWidth: CGFloat = 0

    /// 上一次消费的 entries 的 id 顺序 + theme 指纹。用于 `setEntries` short-circuit
    /// —— SwiftUI reconcile 可能每帧调 updateNSView,若 entries 与 theme 都等价,
    /// 立即返回,不做任何 layout 工作。
    private var lastEntriesSignature: [UUID] = []
    private var lastThemeFingerprint: MarkdownTheme.Fingerprint?

    init(tableView: TranscriptTableView) {
        self.tableView = tableView
        super.init()
    }

    // MARK: - Public entry：setEntries

    /// 新 entries 进来——构造新 row 列表、算 diff、增量 apply。
    ///
    /// Short-circuit：entries id 列表 + theme 指纹都等价 → 立即返回。SwiftUI 的
    /// reconcile 会高频触发 updateNSView，这里必须早退以避免 O(N) 重排。
    func setEntries(_ entries: [MessageEntry], themeChanged: Bool) {
        guard let tableView else { return }
        let themeToUse = theme ?? .default
        let themeFingerprint = themeToUse.fingerprint
        let signature = entries.map { $0.id }

        if signature == lastEntriesSignature, lastThemeFingerprint == themeFingerprint {
            return
        }

        let newRows = TranscriptRowBuilder.build(entries: entries, theme: themeToUse)
        let width = effectiveWidth()

        // Diff：新旧 row 按 stableId + contentHash 比对。
        let transition = TranscriptDiff.compute(
            old: rows,
            new: newRows,
            animated: false)

        appLog(.debug, "TranscriptController",
            "setEntries table=\(Int(tableView.bounds.width)) clip=\(Int(tableView.enclosingScrollView?.contentView.bounds.width ?? 0)) → use=\(Int(width))")

        let t0 = CFAbsoluteTimeGetCurrent()
        // 对新插入 / 内容更新过的 row 先算一次 size，carry-over 的 row 若 width
        // 没变则什么都不做（makeSize 幂等），若 width 变了则算新 layout。
        for (_, row) in transition.inserted { row.makeSize(width: width) }
        for (_, row) in transition.updated { row.makeSize(width: width) }
        for row in transition.finalRows where row.cachedWidth != width {
            row.makeSize(width: width)
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let reusedCount = transition.finalRows.count
            - transition.inserted.count - transition.updated.count
        if !newRows.isEmpty {
            appLog(.info, "TranscriptController",
                "layout rows=\(newRows.count) (+\(transition.inserted.count) / ~\(transition.updated.count) / -\(transition.deleted.count) / reused=\(reusedCount)) in \(ms)ms width=\(Int(width))")
        }

        lastLayoutWidth = width
        lastEntriesSignature = signature
        lastThemeFingerprint = themeFingerprint

        merge(with: transition)
    }

    // MARK: - merge (对齐 Telegram `TableView.merge(with:)`)

    /// 把 transition 应用到 tableView：先 delete（倒序）、后 insert（正序）、
    /// 最后对 updated 位置做 per-row reload。每一步过后都重新给 row 分配 index。
    private func merge(with transition: TranscriptUpdateTransition) {
        guard let tableView else { return }

        let anim: NSTableView.AnimationOptions = transition.animated ? .effectFade : []
        if !transition.animated {
            NSAnimationContext.current.duration = 0
        }

        // 空 transition（比如 theme 变了但 rows 引用未变）：直接赋值即可。
        if transition.isEmpty, rows.count == transition.finalRows.count,
           zip(rows, transition.finalRows).allSatisfy({ $0 === $1 }) {
            return
        }

        tableView.beginUpdates()

        // --- deletes：倒序，避免前面的 remove 让后面的 index 失效。
        if !transition.deleted.isEmpty {
            let desc = transition.deleted.sorted(by: >)
            // 先清 row 侧的 table/index，防止被删的 row 继续反向调用。
            for idx in desc where idx >= 0 && idx < rows.count {
                let row = rows[idx]
                row.table = nil
                row.index = -1
            }
            for idx in desc where idx >= 0 && idx < rows.count {
                rows.remove(at: idx)
            }
            tableView.removeRows(at: IndexSet(desc), withAnimation: anim)
        }

        // --- inserts：正序。此时 `rows` 已经是「删除后」的中间状态，
        // inserted 的 index 是**新列表**中的下标。由于新列表 = 中间态 + 按顺序
        // 插入后的结果，正序遍历时每一步的新下标都落在合法范围。
        if !transition.inserted.isEmpty {
            var insertedIndexes = IndexSet()
            for (i, row) in transition.inserted {
                let insertAt = min(i, rows.count)
                rows.insert(row, at: insertAt)
                insertedIndexes.insert(insertAt)
            }
            tableView.insertRows(at: insertedIndexes, withAnimation: anim)
        }

        // --- updates：已经在 finalRows 对应位置——把旧 row 对象换成新 row，
        // 再对每个 index 单独 reload（视图能复用则 set(row:)，不能复用则 remove+insert）。
        if !transition.updated.isEmpty {
            for (i, row) in transition.updated where i >= 0 && i < rows.count {
                rows[i] = row
            }
        }

        // 关键：此时 `rows` 应该严格等于 `finalRows`。断言一下、同时用 finalRows
        // 覆盖掉可能的排列偏差（按 stableId 对齐）。
        if !rowsMatchFinal(transition.finalRows) {
            // 理论不该到这里——若出现，直接以 finalRows 为准重排。
            appLog(.warning, "TranscriptController",
                "merge: rows drifted from finalRows (rows=\(rows.count) final=\(transition.finalRows.count)); overriding")
            rows = transition.finalRows
        }

        reindexAllRows()
        tableView.endUpdates()

        // updates 的 per-row reload 放在 endUpdates 之后——避免和 insert / remove
        // 的批量动画相互干扰。rowView 若还是同 class 就原地 set，否则 reload。
        for (i, _) in transition.updated where i >= 0 && i < rows.count {
            reloadRowView(at: i, animated: transition.animated)
        }
    }

    private func rowsMatchFinal(_ final: [TranscriptRow]) -> Bool {
        guard rows.count == final.count else { return false }
        for i in 0..<rows.count where rows[i] !== final[i] { return false }
        return true
    }

    private func reindexAllRows() {
        for (i, row) in rows.enumerated() {
            row.table = self
            row.index = i
        }
    }

    // MARK: - Row-level table ops (Telegram TableView.noteHeightOfRow / reloadData(row:))

    /// 单行高度 invalidate —— 调用方一般是 row 自己（`row.noteHeightOfRow()`）。
    /// 视图还挂着就顺便 `set(row:)` 触发重绘。
    func noteHeightOfRow(_ row: Int, animated: Bool = false) {
        guard let tableView, row >= 0, row < rows.count else { return }
        if !animated {
            NSAnimationContext.current.duration = 0
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        if let rv = tableView.rowView(atRow: row, makeIfNecessary: false) as? TranscriptRowView {
            rv.set(row: rows[row])
        }
    }

    /// 单行整体 reload —— 视图类不变时原地 set + noteHeight；变了才做 remove+insert。
    /// 对应 Telegram `reloadData(row:animated:)`。
    func reloadRow(_ row: Int, animated: Bool = false) {
        guard let tableView, row >= 0, row < rows.count else { return }
        reloadRowView(at: row, animated: animated)
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    private func reloadRowView(at row: Int, animated: Bool) {
        guard let tableView, row >= 0, row < rows.count else { return }
        let data = rows[row]

        if let rv = tableView.rowView(atRow: row, makeIfNecessary: false) as? TranscriptRowView,
           type(of: rv) == data.viewClass() {
            rv.set(row: data)
            return
        }
        // 视图类变了——走 remove+insert 让 makeView 拿新类。
        let anim: NSTableView.AnimationOptions = animated ? .effectFade : []
        if !animated { NSAnimationContext.current.duration = 0 }
        tableView.beginUpdates()
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: anim)
        tableView.insertRows(at: IndexSet(integer: row), withAnimation: anim)
        tableView.endUpdates()
    }

    // MARK: - Resize (对齐 Telegram `layoutIfNeeded(with:oldWidth:)`)

    /// 宽度变化入口 —— 逐 row 做 `before/after` height 对比，只对变了的 row 通知
    /// NSTableView。同时保存 / 还原 scroll anchor，让 resize 期间可视区域不漂。
    func tableWidthChanged(_ newWidth: CGFloat) {
        guard let tableView else { return }
        guard newWidth > 0, abs(newWidth - lastLayoutWidth) > 0.5 else { return }
        let oldWidth = lastLayoutWidth
        lastLayoutWidth = newWidth
        appLog(.debug, "TranscriptController",
            "tableWidthChanged \(Int(oldWidth))→\(Int(newWidth)) rows=\(rows.count)")

        guard !rows.isEmpty else { return }

        let anchor = captureScrollAnchor()

        tableView.beginUpdates()
        var changed = IndexSet()
        for (i, row) in rows.enumerated() {
            let before = row.cachedHeight
            row.makeSize(width: newWidth)
            if row.cachedHeight != before {
                changed.insert(i)
            }
        }
        if !changed.isEmpty {
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
        tableView.endUpdates()

        // 宽度变了 ≠ 仅高度变——行内 wrap / bubble geometry 也会变。
        // 所有可视 rowView 都要重画一遍。noteHeightOfRows 只改高度不触发重绘。
        tableView.enumerateAvailableRowViews { view, index in
            guard index >= 0, index < self.rows.count else { return }
            (view as? TranscriptRowView)?.set(row: self.rows[index])
        }

        restoreScrollAnchor(anchor)
    }

    // MARK: - Scroll anchor

    /// (stableId, 该行在 viewport 内的 top 偏移)。resize / merge 前保存，完成后
    /// 用新 `rect(ofRow:)` 反推需要的 clipView origin，让锚点 row 保持在同一
    /// viewport 位置。对齐 Telegram `saveScrollState` / `getScrollY`。
    private struct ScrollAnchor {
        let stableId: AnyHashable
        let topOffset: CGFloat
    }

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return nil }
        let vr = tableView.rows(in: clip.bounds)
        guard vr.length > 0, vr.location >= 0 else { return nil }
        // 取最上面那一行作为锚（flipped 下 = smallest index）。
        let idx = vr.location
        guard idx < rows.count else { return nil }
        let rowRect = tableView.rect(ofRow: idx)
        let topOffset = rowRect.minY - clip.bounds.minY
        return ScrollAnchor(stableId: rows[idx].stableId, topOffset: topOffset)
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor,
              let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return }
        guard let idx = rows.firstIndex(where: { $0.stableId == anchor.stableId }) else {
            return
        }
        let newRect = tableView.rect(ofRow: idx)
        let newY = newRect.minY - anchor.topOffset
        // clamp：别推到文档之外（否则滚动条会反弹）。
        let maxY = max(0, tableView.bounds.height - clip.bounds.height)
        let clamped = max(0, min(newY, maxY))
        guard abs(clamped - clip.bounds.minY) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clamped))
        tableView.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < rows.count else { return 1 }
        return max(1, rows[row].cachedHeight)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard row >= 0, row < rows.count else { return nil }
        let data = rows[row]
        let id = NSUserInterfaceItemIdentifier(data.identifier)
        let rowView: TranscriptRowView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? TranscriptRowView {
            rowView = reused
        } else {
            let cls = data.viewClass()
            rowView = cls.init(frame: .zero)
            rowView.identifier = id
        }
        rowView.set(row: data)
        return rowView
    }

    /// 所有绘制在 rowView，`viewFor` 返回 nil。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        nil
    }

    // MARK: - Helpers

    /// 优先读 clipView(= scroll viewport 可视宽度)。tableView 自己的宽度是
    /// documentView 宽度,可能大于或小于 clipView——rows 要按"可视宽度"排版,
    /// 不是按 tableView 物理宽度。
    private func effectiveWidth() -> CGFloat {
        if let clip = tableView?.enclosingScrollView?.contentView.bounds.width, clip > 0 {
            return clip
        }
        let w = tableView?.bounds.width ?? 0
        return w > 0 ? w : 760
    }
}

import AppKit

/// 持有 `[TranscriptRow]`，实现 `NSTableViewDataSource` / `NSTableViewDelegate`。
///
/// 走**增量 transition** + **async preprocess**：
/// - `setEntries` 同步算 diff（stableId + contentHash）；对新 / 更新过的
///   `AssistantMarkdownRow` kick off 一个 Task 做 batch syntax highlight；
///   Task 完成后 main-actor apply transition——**paint 前 tokens 已就绪，
///   没有 plain→彩色的视觉跳变**。
/// - `tableWidthChanged` 逐 row `makeSize`，仅对 height 实际变化的 row 通知
///   NSTableView；同时保存 / 还原 scroll anchor。
/// - Row 侧可通过 `noteHeightOfRow` / `reloadRow` 反向触发单行刷新（tool block
///   动态展开用）。
/// - 文本选中由 `TranscriptSelectionController` 协调；controller 暴露
///   `notifyRowSelectionChanged` / `redrawAllVisibleRows` 给它。
@MainActor
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: TranscriptTableView?
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

    /// 活跃 preprocess Task。每次新 setEntries 来了就 cancel 当前 Task，避免
    /// 过期 highlight 结果 apply 到已经被换掉的 rows。
    private var activePreprocessTask: Task<Void, Never>?

    /// Generation token。Task 完成时和这个对比，不匹配说明期间发生过新 setEntries
    /// —— 丢弃老结果。
    private var setEntriesGeneration: Int = 0

    /// 文本选中协调器。Controller 持有；`TranscriptTableView` 的鼠标事件直接转给它。
    let selectionController = TranscriptSelectionController()

    init(tableView: TranscriptTableView) {
        self.tableView = tableView
        super.init()
        selectionController.controller = self
    }

    // MARK: - setEntries

    /// 新 entries 进来——diff、preprocess（async）、统一 apply。
    ///
    /// Short-circuit：entries id 列表 + theme 指纹都等价 → 立即返回。
    func setEntries(_ entries: [MessageEntry], themeChanged: Bool) {
        guard let tableView else { return }
        let themeToUse = theme ?? .default
        let themeFingerprint = themeToUse.fingerprint
        let signature = entries.map { $0.id }

        if signature == lastEntriesSignature, lastThemeFingerprint == themeFingerprint {
            return
        }

        setEntriesGeneration += 1
        let generation = setEntriesGeneration
        activePreprocessTask?.cancel()

        let t0 = CFAbsoluteTimeGetCurrent()
        let newRows = TranscriptRowBuilder.build(entries: entries, theme: themeToUse)
        let tBuild = CFAbsoluteTimeGetCurrent()

        let transition = TranscriptDiff.compute(
            old: rows,
            new: newRows,
            animated: false)

        // 收集新 / 更新的 assistant row——它们的 code blocks 需要 highlight。
        // carry-over 的 row 不进——它们的 tokens 上轮已经贴好。
        var assistantRows: [AssistantMarkdownRow] = []
        for (_, row) in transition.inserted { if let a = row as? AssistantMarkdownRow { assistantRows.append(a) } }
        for (_, row) in transition.updated { if let a = row as? AssistantMarkdownRow { assistantRows.append(a) } }

        let width = effectiveWidth()

        lastLayoutWidth = width
        lastEntriesSignature = signature
        lastThemeFingerprint = themeFingerprint

        // Async preprocess + apply。
        let engine = syntaxEngine
        let reusedCount = transition.finalRows.count
            - transition.inserted.count - transition.updated.count
        let deletedCount = transition.deleted.count

        activePreprocessTask = Task { [weak self] in
            let tPre0 = CFAbsoluteTimeGetCurrent()
            let timing = await TranscriptPreprocessor.run(
                rows: assistantRows,
                engine: engine)
            let tPre1 = CFAbsoluteTimeGetCurrent()

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tApply0 = CFAbsoluteTimeGetCurrent()
                // Layout（受 width 影响的那一段）——每行按当前 width 排版。
                // carry-over row 若 cachedWidth 一致则 O(1) 早退。
                for row in transition.finalRows where row.cachedWidth != width {
                    row.makeSize(width: width)
                }
                let tApply1 = CFAbsoluteTimeGetCurrent()
                self.merge(with: transition)
                let tApply2 = CFAbsoluteTimeGetCurrent()

                let parseBuildMs = Int((tBuild - t0) * 1000)
                let diffMs = Int((tPre0 - tBuild) * 1000)
                let preMs = Int((tPre1 - tPre0) * 1000)
                let layoutMs = Int((tApply1 - tApply0) * 1000)
                let mergeMs = Int((tApply2 - tApply1) * 1000)
                let totalMs = Int((tApply2 - t0) * 1000)
                appLog(.info, "TranscriptController",
                    "setEntries total=\(totalMs)ms "
                    + "(+\(transition.inserted.count) / ~\(transition.updated.count) / -\(deletedCount) / reused=\(reusedCount)) "
                    + "parseBuild=\(parseBuildMs) diff=\(diffMs) preprocess=\(preMs)"
                    + " (hl=\(timing.highlightMs)ms code=\(timing.codeBlockCount)) "
                    + "layout=\(layoutMs) merge=\(mergeMs) width=\(Int(width))")
            }
        }
    }

    // MARK: - merge

    /// 把 transition 应用到 tableView。主线程。
    private func merge(with transition: TranscriptUpdateTransition) {
        guard let tableView else { return }

        let anim: NSTableView.AnimationOptions = transition.animated ? .effectFade : []
        if !transition.animated {
            NSAnimationContext.current.duration = 0
        }

        // 空 transition 保护。
        if transition.isEmpty, rows.count == transition.finalRows.count,
           zip(rows, transition.finalRows).allSatisfy({ $0 === $1 }) {
            return
        }

        tableView.beginUpdates()

        if !transition.deleted.isEmpty {
            let desc = transition.deleted.sorted(by: >)
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

        if !transition.inserted.isEmpty {
            var insertedIndexes = IndexSet()
            for (i, row) in transition.inserted {
                let insertAt = min(i, rows.count)
                rows.insert(row, at: insertAt)
                insertedIndexes.insert(insertAt)
            }
            tableView.insertRows(at: insertedIndexes, withAnimation: anim)
        }

        if !transition.updated.isEmpty {
            for (i, row) in transition.updated where i >= 0 && i < rows.count {
                rows[i] = row
            }
        }

        if !rowsMatchFinal(transition.finalRows) {
            appLog(.warning, "TranscriptController",
                "merge: rows drifted from finalRows (rows=\(rows.count) final=\(transition.finalRows.count)); overriding")
            rows = transition.finalRows
        }

        reindexAllRows()
        tableView.endUpdates()

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

    // MARK: - Row-level reload (row 自己反向调，或 selection 写入后用)

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
        let anim: NSTableView.AnimationOptions = animated ? .effectFade : []
        if !animated { NSAnimationContext.current.duration = 0 }
        tableView.beginUpdates()
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: anim)
        tableView.insertRows(at: IndexSet(integer: row), withAnimation: anim)
        tableView.endUpdates()
    }

    // MARK: - Selection hooks (called by TranscriptSelectionController)

    func notifyRowSelectionChanged(index: Int) {
        guard let tableView, index >= 0, index < rows.count else { return }
        if let rv = tableView.rowView(atRow: index, makeIfNecessary: false) as? TranscriptRowView {
            rv.set(row: rows[index])
        }
    }

    func notifyRowSelectionCleared(stableId: AnyHashable) {
        guard let tableView else { return }
        if let row = rows.first(where: { $0.stableId == stableId }),
           let selectable = row as? TextSelectable {
            selectable.clearSelection()
        }
        if let idx = rows.firstIndex(where: { $0.stableId == stableId }),
           let rv = tableView.rowView(atRow: idx, makeIfNecessary: false) as? TranscriptRowView {
            rv.set(row: rows[idx])
        }
    }

    func redrawAllVisibleRows() {
        guard let tableView else { return }
        tableView.enumerateAvailableRowViews { view, index in
            guard index >= 0, index < self.rows.count else { return }
            (view as? TranscriptRowView)?.set(row: self.rows[index])
        }
    }

    // MARK: - Resize

    func tableWidthChanged(_ newWidth: CGFloat) {
        guard let tableView else { return }
        guard newWidth > 0, abs(newWidth - lastLayoutWidth) > 0.5 else { return }
        let oldWidth = lastLayoutWidth
        lastLayoutWidth = newWidth
        appLog(.info, "TranscriptController",
            "resize \(Int(oldWidth))→\(Int(newWidth)) rows=\(rows.count)")

        guard !rows.isEmpty else { return }

        let anchor = captureScrollAnchor()

        let t0 = CFAbsoluteTimeGetCurrent()
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
        let layoutMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)

        tableView.enumerateAvailableRowViews { view, index in
            guard index >= 0, index < self.rows.count else { return }
            (view as? TranscriptRowView)?.set(row: self.rows[index])
        }

        restoreScrollAnchor(anchor)

        appLog(.debug, "TranscriptController",
            "resize done layout=\(layoutMs)ms changed=\(changed.count)")
    }

    // MARK: - Scroll anchor

    private struct ScrollAnchor {
        let stableId: AnyHashable
        let topOffset: CGFloat
    }

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return nil }
        let vr = tableView.rows(in: clip.bounds)
        guard vr.length > 0, vr.location >= 0 else { return nil }
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
        let maxY = max(0, tableView.bounds.height - clip.bounds.height)
        let clamped = max(0, min(newY, maxY))
        guard abs(clamped - clip.bounds.minY) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clamped))
        tableView.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        nil
    }

    // MARK: - Helpers

    private func effectiveWidth() -> CGFloat {
        if let clip = tableView?.enclosingScrollView?.contentView.bounds.width, clip > 0 {
            return clip
        }
        let w = tableView?.bounds.width ?? 0
        return w > 0 ? w : 760
    }
}

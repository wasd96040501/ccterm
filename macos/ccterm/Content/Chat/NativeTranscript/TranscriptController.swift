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

    /// viewWillStartLiveResize 时抓取的 scroll anchor，在 viewDidEndLiveResize
    /// 统一恢复——对齐 Telegram `TableView.swift` 的 `saveScrollState` 只在
    /// `!inLiveResize` 时跑（live 期间每帧 anchor 抖动没意义）。
    private var liveResizeAnchor: ScrollAnchor?

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

    /// 用户手动展开过的 UserBubble 的 stableId 集合。
    ///
    /// Sticky：toggle 过就进 set，再 toggle 出 set。resize 换宽度不动这里。
    /// Row 上的 `isExpanded` 只是 render-time cache，source of truth 是这个 set
    /// ——controller 在每次 layout pass 之前把 row.isExpanded sync 回来。
    private var expandedUserBubbles: Set<AnyHashable> = []

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
        let newRows = TranscriptRowBuilder.build(
            entries: entries,
            theme: themeToUse,
            expandedUserBubbles: expandedUserBubbles)
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
                // Sync collapse state to finalRows **before** layout. insert/update
                // row 已由 builder 传对；carry-over row 的 cachedWidth 可能已对齐，
                // 但两次 setEntries 之间 set 可能被 toggle 过，这里统一回填。
                for row in transition.finalRows {
                    if let u = row as? UserBubbleRow {
                        u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
                    }
                }
                // Layout——逐行 makeSize。makeSize 内部 `widthChanged || stateChanged`
                // guard 负责 O(1) early-return；不要在外部加 `where cachedWidth != width`
                // 过滤，否则 state sync 后 cachedWidth 对齐的 carry-over row 会 skip，
                // 几何漏算。
                for row in transition.finalRows {
                    row.makeSize(width: width)
                }
                let tApply1 = CFAbsoluteTimeGetCurrent()
                self.merge(with: transition)
                // Prune：从 set 里摘掉被删的 user bubble 的 stableId。
                // deleted 存的是 index；用 `rows` 快照前的索引不安全，改走「diff
                // finalRows 之外的老 row」路径：merge 之后 rows 已 == finalRows，
                // expandedUserBubbles 里不在 rows 中的 stableId 全部摘掉。
                let liveIds = Set(self.rows.map { $0.stableId })
                self.expandedUserBubbles.formIntersection(liveIds)
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

    /// 宽度变化入口。live resize 期间只重排可见行，非 live 走全量 + anchor。
    /// 对齐 Telegram `TableView.swift:3753-3771` 的 live/非 live 分支。
    ///
    /// 关键：即使 clamped width 没变（例如 window 在 > maxContentWidth 区间内
    /// 拖动，rowLayoutWidth 恒等于 820），也必须 `setNeedsDisplay` 可见 rowView
    /// ——`TranscriptRowView.draw` 里的 CTM inset 依赖 rowView.bounds.width，
    /// 不重绘的话居中 offset 会滞留到 `viewDidEndLiveResize` 才跳。代价：仅
    /// 可见行 layer 重 rasterize（CTLine 已缓存），无 Core Text 重排。
    func tableWidthChanged(_ rawNewWidth: CGFloat) {
        guard let tableView else { return }
        guard rawNewWidth > 0 else { return }
        let newWidth = clampedRowLayoutWidth(from: rawNewWidth)
        let layoutChanged = abs(newWidth - lastLayoutWidth) > 0.5

        if !layoutChanged {
            // clamped 没动（典型：两个宽度都 > maxContentWidth），
            // 但 rowView bounds 变了 → 刷 inset 重绘，别的不动。
            redrawVisibleRows()
            return
        }

        let oldWidth = lastLayoutWidth
        lastLayoutWidth = newWidth
        appLog(.info, "TranscriptController",
            "resize \(Int(oldWidth))→\(Int(newWidth)) rows=\(rows.count) live=\(tableView.inLiveResize)")

        guard !rows.isEmpty else { return }

        if tableView.inLiveResize {
            relayoutVisibleRows(width: newWidth)
        } else {
            let anchor = captureScrollAnchor()
            relayoutAllRows(width: newWidth)
            restoreScrollAnchor(anchor)
        }
    }

    /// 只刷新可见 rowView 的 layer，不动 layout / cachedWidth / scroll anchor。
    /// 用于 "rowView.bounds.width 变了但 row 排版宽度没变" 的场景，让 CTM
    /// 基于新 bounds 重算居中 inset。
    private func redrawVisibleRows() {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return }
        let visible = tableView.rows(in: clip.bounds)
        guard visible.length > 0, visible.location >= 0 else { return }
        let end = min(visible.location + visible.length, rows.count)
        for i in max(0, visible.location)..<end {
            if let rv = tableView.rowView(atRow: i, makeIfNecessary: false) as? TranscriptRowView {
                rv.layer?.setNeedsDisplay()
            }
        }
    }

    /// viewWillStartLiveResize 钩子：抓 scroll anchor 备用。
    func beginLiveResize() {
        liveResizeAnchor = captureScrollAnchor()
    }

    /// viewDidEndLiveResize 钩子：补跑所有 cachedWidth != finalWidth 的行
    /// （通常是不可见行——可见行已在 live 期间逐帧 relayoutVisibleRows 刷过），
    /// 然后恢复 beginLiveResize 时保存的 anchor。
    func endLiveResize(finalWidth rawWidth: CGFloat) {
        guard let tableView else { liveResizeAnchor = nil; return }
        let width = clampedRowLayoutWidth(from: rawWidth)

        let t0 = CFAbsoluteTimeGetCurrent()
        tableView.beginUpdates()
        NSAnimationContext.current.duration = 0
        var changed = IndexSet()
        for (i, row) in rows.enumerated() where row.cachedWidth != width {
            let before = row.cachedHeight
            row.makeSize(width: width)
            if row.cachedHeight != before { changed.insert(i) }
        }
        if !changed.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
        tableView.endUpdates()
        lastLayoutWidth = width

        tableView.enumerateAvailableRowViews { view, index in
            guard index >= 0, index < self.rows.count else { return }
            (view as? TranscriptRowView)?.set(row: self.rows[index])
        }

        restoreScrollAnchor(liveResizeAnchor)
        liveResizeAnchor = nil

        let layoutMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        appLog(.debug, "TranscriptController",
            "resize end layout=\(layoutMs)ms changed=\(changed.count)")
    }

    private func relayoutVisibleRows(width: CGFloat) {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let visible = tableView.rows(in: clip.bounds)
        guard visible.length > 0, visible.location >= 0 else { return }

        tableView.beginUpdates()
        NSAnimationContext.current.duration = 0
        var changed = IndexSet()
        let end = min(visible.location + visible.length, rows.count)
        for i in max(0, visible.location)..<end {
            let row = rows[i]
            let before = row.cachedHeight
            row.makeSize(width: width)
            if row.cachedHeight != before { changed.insert(i) }
        }
        if !changed.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
        tableView.endUpdates()

        tableView.enumerateAvailableRowViews { view, index in
            guard index >= 0, index < self.rows.count else { return }
            (view as? TranscriptRowView)?.set(row: self.rows[index])
        }

        let layoutMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        appLog(.debug, "TranscriptController",
            "resize live visible=\(visible.length) layout=\(layoutMs)ms changed=\(changed.count)")
    }

    private func relayoutAllRows(width: CGFloat) {
        guard let tableView else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        tableView.beginUpdates()
        var changed = IndexSet()
        for (i, row) in rows.enumerated() {
            let before = row.cachedHeight
            row.makeSize(width: width)
            if row.cachedHeight != before { changed.insert(i) }
        }
        if !changed.isEmpty {
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
        tableView.endUpdates()

        tableView.enumerateAvailableRowViews { view, index in
            guard index >= 0, index < self.rows.count else { return }
            (view as? TranscriptRowView)?.set(row: self.rows[index])
        }

        let layoutMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        appLog(.debug, "TranscriptController",
            "resize full layout=\(layoutMs)ms changed=\(changed.count)")
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
        let raw: CGFloat
        if let clip = tableView?.enclosingScrollView?.contentView.bounds.width, clip > 0 {
            raw = clip
        } else {
            let w = tableView?.bounds.width ?? 0
            raw = w > 0 ? w : 760
        }
        return clampedRowLayoutWidth(from: raw)
    }

    /// clip 宽度 → 行排版宽度：上限 `TranscriptTheme.maxContentWidth`，
    /// 窄于上限时原样返回（= 贴边占满），宽于上限时夹到上限（= 居中列）。
    private func clampedRowLayoutWidth(from rawClipWidth: CGFloat) -> CGFloat {
        let maxW = TranscriptTheme(markdown: theme ?? .default).maxContentWidth
        return min(rawClipWidth, maxW)
    }

    /// row 内容居中的左 inset：`(rowRect.width - row.cachedWidth) / 2`。
    /// TranscriptRowView.draw 用它做 CTM 平移；hit-test 路径用它把 documentPoint
    /// 归一到 row 的 layout 坐标系（0 = 内容列左边，而非 rowRect 左边）。
    func contentInset(forRow idx: Int, rowRect: CGRect) -> CGFloat {
        guard idx >= 0, idx < rows.count else { return 0 }
        return max(0, (rowRect.width - rows[idx].cachedWidth) / 2)
    }

    // MARK: - Row-local point conversion

    /// 单个 row 的 documentPoint→rowLocalPoint 变换上下文。把 `(rowRect, inset)`
    /// 一次算好缓存起来，多次变换（典型如 selection 的 upper/lower 两点）只需
    /// 调 `toRowLocal(_:)`，避免重复 `rect(ofRow:)` 和 `contentInset` 调用。
    struct RowLocalContext {
        let rowIndex: Int
        let rowRect: CGRect
        let inset: CGFloat

        func toRowLocal(_ documentPoint: CGPoint) -> CGPoint {
            CGPoint(
                x: documentPoint.x - rowRect.origin.x - inset,
                y: documentPoint.y - rowRect.origin.y)
        }
    }

    /// `documentPoint` 命中哪一行 + 该行的坐标变换上下文。miss 任何一行返回 nil。
    func rowLocalContext(at documentPoint: CGPoint) -> RowLocalContext? {
        guard let tableView else { return nil }
        return rowLocalContext(forRow: tableView.row(at: documentPoint))
    }

    /// 已知 rowIndex，构造该行的坐标变换上下文。越界返回 nil。
    func rowLocalContext(forRow rowIndex: Int) -> RowLocalContext? {
        guard let tableView, rowIndex >= 0, rowIndex < rows.count else { return nil }
        let rowRect = tableView.rect(ofRow: rowIndex)
        let inset = contentInset(forRow: rowIndex, rowRect: rowRect)
        return RowLocalContext(rowIndex: rowIndex, rowRect: rowRect, inset: inset)
    }

    // MARK: - Link hit-test

    /// 命中 point 处的 `.link` 属性。链接存放格式沿用
    /// `MarkdownAttributedBuilder`：`.link` 挂 `String`(markdown destination)。
    /// 这里转成 URL；不合法的 URL 不返回。
    func linkURL(atDocumentPoint documentPoint: CGPoint) -> URL? {
        guard let ctx = rowLocalContext(at: documentPoint) else { return nil }
        guard let selectable = rows[ctx.rowIndex] as? TextSelectable else { return nil }
        let regions = selectable.selectableRegions
        guard !regions.isEmpty else { return nil }
        let pointInRow = ctx.toRowLocal(documentPoint)

        for region in regions where region.frameInRow.contains(pointInRow) {
            let local = CGPoint(
                x: pointInRow.x - region.frameInRow.origin.x,
                y: pointInRow.y - region.frameInRow.origin.y)
            guard let ci = region.layout.characterIndex(at: local) else { continue }
            let attr = region.layout.attributed
            let idx = max(0, min(Int(ci), attr.length - 1))
            guard idx >= 0, idx < attr.length else { continue }
            let value = attr.attribute(.link, at: idx, effectiveRange: nil)
            if let url = value as? URL { return url }
            if let s = value as? String, let url = URL(string: s) { return url }
        }
        return nil
    }

    // MARK: - Code block click-to-copy

    /// 只读命中测试——cursor 判定用。返回 true 表示 point 下方有 code block
    /// header，cursor 要变 pointingHand。
    func codeBlockHit(atDocumentPoint documentPoint: CGPoint) -> Bool {
        return resolveCodeBlockHit(atDocumentPoint: documentPoint) != nil
    }

    /// mouseUp 一站式处理：命中 header 就写 pasteboard + 触发 icon checkmark
    /// 闪烁。返回 true 表示 click 已被消费。
    func performCodeBlockCopy(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard let resolved = resolveCodeBlockHit(atDocumentPoint: documentPoint) else {
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(resolved.hit.code, forType: .string)
        let rowIndex = resolved.rowIndex
        resolved.row.markCodeBlockCopied(
            segmentIndex: resolved.hit.segmentIndex
        ) { [weak self] in
            self?.redrawRow(at: rowIndex)
        }
        return true
    }

    private struct CodeBlockResolved {
        let row: AssistantMarkdownRow
        let rowIndex: Int
        let hit: AssistantMarkdownRow.CodeBlockHitInfo
    }

    private func resolveCodeBlockHit(atDocumentPoint documentPoint: CGPoint)
        -> CodeBlockResolved?
    {
        guard let ctx = rowLocalContext(at: documentPoint) else { return nil }
        guard let row = rows[ctx.rowIndex] as? AssistantMarkdownRow else { return nil }
        let pointInRow = ctx.toRowLocal(documentPoint)
        guard let hit = row.codeBlockHit(atRowPoint: pointInRow) else { return nil }
        return CodeBlockResolved(row: row, rowIndex: ctx.rowIndex, hit: hit)
    }

    private func redrawRow(at index: Int) {
        guard let tableView else { return }
        guard index >= 0, index < rows.count else { return }
        guard let rowView = tableView.rowView(atRow: index, makeIfNecessary: false)
            as? TranscriptRowView else { return }
        // Same path as redrawAllVisibleRows — hands the row back to its view,
        // which triggers `layer.setNeedsDisplay()`. We don't re-run makeSize
        // because the checkmark flip is a pure state change.
        rowView.set(row: rows[index])
    }

    // MARK: - User bubble collapse toggle

    /// 只读命中测试：point 是否在某个 UserBubbleRow 的 chevron 上。
    /// cursorUpdate 用——优先级高于 `linkURL`（chevron 叠 URL 时显示 pointingHand
    /// 但语义是 toggle，不是 open URL——cursor 上只要表达"可点击"即可）。
    func isOverUserBubbleChevron(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard let ctx = rowLocalContext(at: documentPoint) else { return false }
        guard let row = rows[ctx.rowIndex] as? UserBubbleRow else { return false }
        let pointInRow = ctx.toRowLocal(documentPoint)
        return row.chevronHitRectInRow()?.contains(pointInRow) == true
    }

    /// 命中 UserBubbleRow 右下 chevron → 翻转折叠状态，刷新行高。
    /// 返回 true 表示本次 click 已被消费；调用方应跳过 linkURL 分支。
    ///
    /// 关键：不走 `setEntries` / rebuild——只改 set + row 字段 + `makeSize` +
    /// `noteHeightOfRow`。`makeSize` 两阶段实现让 state-only 变更不重跑 CT。
    func toggleUserBubble(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard lastLayoutWidth > 0 else { return false }
        guard let ctx = rowLocalContext(at: documentPoint) else { return false }
        guard let row = rows[ctx.rowIndex] as? UserBubbleRow else { return false }
        let pointInRow = ctx.toRowLocal(documentPoint)
        guard let hit = row.chevronHitRectInRow(), hit.contains(pointInRow) else {
            return false
        }

        let id = row.stableId
        if expandedUserBubbles.contains(id) {
            expandedUserBubbles.remove(id)
            row.isExpanded = false
        } else {
            expandedUserBubbles.insert(id)
            row.isExpanded = true
        }
        row.makeSize(width: lastLayoutWidth)
        noteHeightOfRow(ctx.rowIndex)
        return true
    }
}

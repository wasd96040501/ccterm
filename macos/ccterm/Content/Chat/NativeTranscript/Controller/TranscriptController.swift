import AppKit

/// 持有 `[TranscriptRow]`，实现 `NSTableViewDataSource` / `NSTableViewDelegate`。
///
/// 设计关键：**意图由 caller 传入**（`TranscriptUpdateReason`），controller 不从
/// entries delta 形状推断。对齐 Telegram macOS 的 `ChatController`→`TableView`
/// 分层：storage 层给语义（reason / scrollPosition），TableView 只做 diff + merge
/// + 按 intent 应用 scroll。
///
/// Pipeline 由 reason 决定：
/// - `.idle`：短路返回。
/// - `.initialPaint`：viewport-first bottom。Phase 1 逆向 accumulate 到 viewport 高度
///   并立即挂载、scroll 到底；Phase 2 异步 prepare + highlight 余下 prefix 并前插，
///   scroll 切到 `.anchor(rows[0])` 保住视觉。
/// - `.prependHistory`：全量 diff + `.anchor(rows[0])`。
/// - `.liveAppend`：只 prepare + insert 尾部新增 entries，scroll `.preserve`。
/// - `.update`：全量 diff + `.preserve`。
///
/// Short-circuit：entries id 列表 + theme 指纹都等价且 reason 非 idle → 立即返回。
@MainActor
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: TranscriptTableView?
    var rows: [TranscriptRow] = []

    var theme: MarkdownTheme?
    var syntaxEngine: SyntaxHighlightEngine?

    /// 上次排版时使用的宽度。宽度真正变化才重算。
    var lastLayoutWidth: CGFloat = 0

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
    var activePreprocessTask: Task<Void, Never>?

    /// Generation token。Task 完成时和这个对比，不匹配说明期间发生过新 setEntries
    /// —— 丢弃老结果。
    var setEntriesGeneration: Int = 0

    /// 文本选中协调器。Controller 持有；`TranscriptTableView` 的鼠标事件直接转给它。
    let selectionController = TranscriptSelectionController()

    /// 用户点 sidebar → `ChatHistoryView.task` 入口记录的时间戳。controller 在
    /// 首个 `.initialPaint` 的 Phase 2 merge 完成时读这个值算 TTFP，emit 后清零
    /// —— 一次性指标，不会重复打印。
    var openStartedAt: CFAbsoluteTime?

    /// session-open 的 cache delta baseline。`.initialPaint` 入口记录；Phase 2
    /// merge 出口做 delta 算 hit/miss。
    var openCacheHitBaseline: Int = 0
    var openCacheMissBaseline: Int = 0

    /// 用户手动展开过的 UserBubble 的 stableId 集合。
    ///
    /// Sticky：toggle 过就进 set，再 toggle 出 set。resize 换宽度不动这里。
    /// Row 上的 `isExpanded` 只是 render-time cache，source of truth 是这个 set
    /// ——controller 在每次 layout pass 之前把 row.isExpanded sync 回来。
    var expandedUserBubbles: Set<AnyHashable> = []

    /// SwiftUI 在 per-session `.id(sessionId)` 的 NSView 刚 `makeNSView` 出来、
    /// AppKit 还没 layout 之前就会调 `updateNSView`——此时 `clipView.bounds` /
    /// `tableView.bounds` 都是 0。如果直接跑 pipeline，`effectiveWidth` 走到最末
    /// const 760 fallback，`phase1Budget` 得 `fallback-zero`，phase1 只挂 1 行、
    /// 宽度 bucket 也错（cache 大概率 miss）。
    ///
    /// 解法：`setEntries` 检测到 dims 全零 → 把 args 存这里，不跑 pipeline。
    /// AppKit 后续 layout 会触发 `setFrameSize` → `tableWidthChanged`（已经是
    /// layout-ready 的信号），在那里 flush 一次即可。
    ///
    /// 没有 DispatchQueue.main.async —— 纯 AppKit 事件驱动，对齐 Telegram
    /// `TableView` 里 "等 view 有 window + frame 再跑首帧" 的语义。
    private struct PendingSetEntries {
        let entries: [MessageEntry]
        let reason: TranscriptUpdateReason
        let themeChanged: Bool
        let scrollHint: SavedScrollAnchor?
    }
    private var pendingSetEntries: PendingSetEntries?

    init(tableView: TranscriptTableView) {
        self.tableView = tableView
        super.init()
        selectionController.controller = self
    }

    // MARK: - setEntries

    /// 渲染入口。按 `reason` dispatch 到对应 pipeline；不做任何 delta 形状推断。
    ///
    /// Short-circuit：`.idle` 立即返回；其它 reason 下如果 entries signature +
    /// theme fingerprint 都等价也立即返回（SwiftUI reconcile 可能每帧调 update）。
    func setEntries(
        _ entries: [MessageEntry],
        reason: TranscriptUpdateReason,
        themeChanged: Bool,
        scrollHint: SavedScrollAnchor? = nil
    ) {
        guard tableView != nil else { return }
        let hintTag: String
        if let h = scrollHint {
            hintTag = "hint(entry=\(h.entryId.uuidString.prefix(8))…,top=\(String(format: "%.1f", h.topOffset)))"
        } else {
            hintTag = "hint=nil"
        }
        appLog(.info, "TranscriptController",
            "[setEntries] enter reason=\(reason.logTag) entries=\(entries.count) "
            + "layoutReady=\(isLayoutReady()) rows=\(rows.count) "
            + "lastSigCount=\(lastEntriesSignature.count) \(hintTag)")
        if case .idle = reason { return }

        // Layout not ready yet (刚 makeNSView + updateNSView 先于第一次 layout)。
        // 不跑 pipeline —— 缓存到 pending，由 `tableWidthChanged` 在真实 frame
        // 到手后 flush。每次 stash 覆盖旧 pending，天然采用最新 snapshot。
        if !isLayoutReady() {
            if let prev = pendingSetEntries {
                appLog(.info, "TranscriptController",
                    "[setEntries] stash-overwrite prev=\(prev.reason.logTag)"
                    + "(entries=\(prev.entries.count)) → new=\(reason.logTag)"
                    + "(entries=\(entries.count))")
            } else {
                appLog(.info, "TranscriptController",
                    "[setEntries] stash-new reason=\(reason.logTag) entries=\(entries.count)")
            }
            pendingSetEntries = PendingSetEntries(
                entries: entries, reason: reason,
                themeChanged: themeChanged, scrollHint: scrollHint)
            return
        }

        let mdTheme = theme ?? .default
        let themeFingerprint = mdTheme.fingerprint
        let signature = entries.map { $0.id }

        if !themeChanged,
           signature == lastEntriesSignature,
           lastThemeFingerprint == themeFingerprint {
            return
        }

        setEntriesGeneration += 1
        let generation = setEntriesGeneration
        activePreprocessTask?.cancel()

        let t0 = CFAbsoluteTimeGetCurrent()
        let width = effectiveWidth()
        let expandedSnapshot = expandedUserBubbles
        let engine = syntaxEngine
        let transcriptTheme = TranscriptTheme(markdown: mdTheme)

        // Snapshot cache baseline 只对 `.initialPaint` 有语义（= session-open）。
        if case .initialPaint = reason, openStartedAt != nil {
            openCacheHitBaseline = TranscriptPrepareCache.shared.hitCount
            openCacheMissBaseline = TranscriptPrepareCache.shared.missCount
        }

        // 保留 `.liveAppend` 需要的旧前缀长度——在覆盖前 snapshot 一下。
        let oldSigCount = lastEntriesSignature.count

        lastLayoutWidth = width
        lastEntriesSignature = signature
        lastThemeFingerprint = themeFingerprint

        switch reason {
        case .idle:
            return  // already short-circuited above

        case .initialPaint:
            // 有 hint + 能在 entries 中找到 anchor entry → 围绕 anchor 展开；
            // 否则 fallback 到 tail + `.bottom`（首次打开 / 锚点已被删 /
            // entries 变化后 anchor 不在里面）。
            if let hint = scrollHint,
               let anchorIdx = entries.firstIndex(where: { $0.id == hint.entryId })
            {
                runViewportFirstAroundAnchor(
                    entries: entries,
                    anchorEntryIndex: anchorIdx,
                    anchorTopOffset: hint.topOffset,
                    theme: transcriptTheme, width: width,
                    expandedSnapshot: expandedSnapshot, engine: engine,
                    generation: generation, t0: t0)
            } else {
                runViewportFirstBottom(
                    entries: entries,
                    theme: transcriptTheme, width: width,
                    expandedSnapshot: expandedSnapshot, engine: engine,
                    generation: generation, t0: t0)
            }

        case .prependHistory:
            runFullDiffMerge(
                entries: entries,
                theme: transcriptTheme, width: width,
                expandedSnapshot: expandedSnapshot, engine: engine,
                generation: generation, t0: t0,
                scroll: anchorToCurrentTop() ?? .preserve,
                tag: "prepend")

        case .liveAppend:
            runLiveAppend(
                entries: entries,
                oldSigCount: oldSigCount,
                theme: transcriptTheme, width: width,
                expandedSnapshot: expandedSnapshot, engine: engine,
                generation: generation, t0: t0)

        case .update:
            runFullDiffMerge(
                entries: entries,
                theme: transcriptTheme, width: width,
                expandedSnapshot: expandedSnapshot, engine: engine,
                generation: generation, t0: t0,
                scroll: .preserve,
                tag: "update")
        }
    }

    /// `.prependHistory` 专用：捕获当前 rows[0] 的 (stableId, topOffset) 作为
    /// anchor。rows 空 / clipView 缺失时返回 nil（caller 降级为 `.preserve`；此时
    /// 视觉上等价——因为本来就没有首屏可锚）。
    func anchorToCurrentTop() -> TranscriptScrollIntent? {
        guard let tv = tableView, !rows.isEmpty,
              let clip = tv.enclosingScrollView?.contentView else { return nil }
        let rect = tv.rect(ofRow: 0)
        return .anchor(stableId: rows[0].stableId,
                       topOffset: rect.minY - clip.bounds.minY)
    }

    /// 给 view 层（SwiftUI `.onDisappear`）调：把当前 scroll 位置打包成
    /// `SavedScrollAnchor`，调用方写回 `SessionHandle2.savedScrollAnchor`。
    ///
    /// 返回 nil 有两种语义：
    /// 1. 用户在内容底部 → 下次打开直接贴底即可，无需锚
    /// 2. rows 空 / clipView 不可用 → 没得捕
    ///
    /// 两种都让 `.loaded` re-entry 走 fallback 到 `.bottom`，都是预期行为。
    func captureScrollHint() -> SavedScrollAnchor? {
        guard let tv = tableView, !rows.isEmpty,
              let clip = tv.enclosingScrollView?.contentView else { return nil }

        // 贴底特判：clip 已经滚到内容底部（或更往下）→ nil。阈值 2pt 容错。
        let maxY = max(0, tv.bounds.height - clip.bounds.height)
        if clip.bounds.minY >= maxY - 2 { return nil }

        // 找到当前可视范围里最顶的 row。
        let visible = tv.rows(in: clip.bounds)
        guard visible.length > 0, visible.location >= 0,
              visible.location < rows.count else { return nil }
        let idx = visible.location
        guard let entryId = Self.entryId(fromRowStableId: rows[idx].stableId) else {
            return nil
        }
        let rect = tv.rect(ofRow: idx)
        return SavedScrollAnchor(
            entryId: entryId,
            topOffset: rect.minY - clip.bounds.minY)
    }

    /// 从 `TranscriptRow.stableId` 反查源 `MessageEntry.id`。
    ///
    /// 规则见 `TranscriptRowBuilder`：
    /// - user / placeholder: `stableId` 直接就是 entry.id (UUID)
    /// - assistant: `stableId` 形如 `"<uuid>-md-N"` / `"<uuid>-tool-N"` (String)，
    ///   前五段组成 entry 的 UUID
    /// - group entry: `stableId` 是 group.id (UUID)
    static func entryId(fromRowStableId stableId: AnyHashable) -> UUID? {
        if let uuid = stableId.base as? UUID { return uuid }
        if let s = stableId.base as? String {
            // UUID is 8-4-4-4-12 = 5 dash-separated hex groups
            let parts = s.split(separator: "-")
            guard parts.count >= 5 else { return nil }
            let uuidStr = parts.prefix(5).joined(separator: "-")
            return UUID(uuidString: uuidStr)
        }
        return nil
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

    func reloadRowView(at row: Int, animated: Bool) {
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

    /// `clipView` 拿到了真实高度 → viewport-first pipeline 可以安全跑
    /// （`phase1Budget` 会命中 `"ok"` 分支，不再走 fallback）。
    ///
    /// 只看 `clip.height` —— tableView 自己可能短暂是 1×1 或其他 degenerate 值，
    /// 但只有 clipView 代表真实 viewport；clipView=0 时任何 `phase1Budget` 都
    /// 不可靠。
    private func isLayoutReady() -> Bool {
        return (tableView?.enclosingScrollView?.contentView.bounds.height ?? 0) > 0
    }

    /// 宽度变化入口。live resize 期间只重排可见行，非 live 走全量 + anchor。
    ///
    /// 同时承担 pending setEntries 的 flush：SwiftUI 在 layout 完成前已经把
    /// 最新 entries 存到 `pendingSetEntries`，此时 AppKit 刚跑完 layout 把真实
    /// frame 传下来——正好喂 pending 一次，走完整 pipeline。
    func tableWidthChanged(_ rawNewWidth: CGFloat) {
        guard let tableView else { return }
        guard rawNewWidth > 0 else { return }

        // Flush pending —— 在 resize 本身的 layout 逻辑之前：pending 要走完整
        // setEntries（含 Phase 1 + Phase 2），而不是 relayoutAllRows 的 in-place
        // makeSize 路径（rows 可能还空）。
        if let pending = pendingSetEntries, isLayoutReady() {
            appLog(.info, "TranscriptController",
                "[setEntries] flush-pending reason=\(pending.reason.logTag) "
                + "entries=\(pending.entries.count) "
                + "hasHint=\(pending.scrollHint != nil)")
            pendingSetEntries = nil
            setEntries(
                pending.entries, reason: pending.reason,
                themeChanged: pending.themeChanged,
                scrollHint: pending.scrollHint)
            // setEntries 自己会更新 lastLayoutWidth；后面的 resize 早退即可。
            return
        }

        let newWidth = clampedRowLayoutWidth(from: rawNewWidth)
        let layoutChanged = abs(newWidth - lastLayoutWidth) > 0.5

        if !layoutChanged {
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

    func beginLiveResize() {
        liveResizeAnchor = captureScrollAnchor()
    }

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
    func contentInset(forRow idx: Int, rowRect: CGRect) -> CGFloat {
        guard idx >= 0, idx < rows.count else { return 0 }
        return max(0, (rowRect.width - rows[idx].cachedWidth) / 2)
    }

}

// MARK: - Diag helpers

extension TranscriptUpdateReason {
    /// Short tag for log lines. Mirrors `.logTag` on `TranscriptScrollIntent`.
    var logTag: String {
        switch self {
        case .idle: return "idle"
        case .initialPaint: return "initialPaint"
        case .prependHistory: return "prependHistory"
        case .liveAppend: return "liveAppend"
        case .update: return "update"
        }
    }
}

extension TranscriptScrollIntent {
    /// Nil for non-anchor intents; the payload for `.anchor`. Used by the
    /// diag `logVisualSnapshot` to compute actual-vs-expected top offset.
    var anchorStableId: AnyHashable? {
        if case .anchor(let sid, _) = self { return sid }
        return nil
    }

    var anchorTopOffset: CGFloat? {
        if case .anchor(_, let top) = self { return top }
        return nil
    }
}

import AppKit

/// 持有 `[ComponentRow]`,实现 `NSTableViewDataSource` / `NSTableViewDelegate`。
///
/// 设计关键:**意图由 caller 传入**(`TranscriptUpdateReason`),controller 不从
/// entries delta 形状推断。对齐 Telegram macOS 的 `ChatController`→`TableView`
/// 分层:storage 层给语义(reason / scrollPosition),TableView 只做 diff + merge
/// + 按 intent 应用 scroll。
///
/// Pipeline 由 reason 决定:
/// - `.idle`:短路返回。
/// - `.initialPaint`:viewport-first bottom。Phase 1 逆向 accumulate 到 viewport 高度
///   并立即挂载、scroll 到底;Phase 2 异步 prepare + highlight 余下 prefix 并前插,
///   scroll 切到 `.anchor(rows[0])` 保住视觉。
/// - `.prependHistory`:全量 diff + `.anchor(rows[0])`。
/// - `.liveAppend`:只 prepare + insert 尾部新增 entries,scroll `.preserve`。
/// - `.update`:全量 diff + `.preserve`。
@MainActor
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: TranscriptTableView?
    var rows: [ComponentRow] = []

    var theme: MarkdownTheme?
    var syntaxEngine: SyntaxHighlightEngine?

    /// 上次排版时使用的宽度。宽度真正变化才重算。
    var lastLayoutWidth: CGFloat = 0

    /// viewWillStartLiveResize 时抓取的 scroll anchor。
    private var liveResizeAnchor: ScrollAnchor?

    /// Short-circuit signature。
    private var lastEntriesSignature: [UUID] = []
    private var lastThemeFingerprint: MarkdownTheme.Fingerprint?

    /// 活跃 preprocess Task。
    var activePreprocessTask: Task<Void, Never>?

    /// Generation token。
    var setEntriesGeneration: Int = 0

    /// 文本选中协调器。
    let selectionController = TranscriptSelectionController()

    /// 用户点 sidebar → `ChatHistoryView.task` 入口记录的时间戳。
    var openStartedAt: CFAbsoluteTime?
    var openCacheHitBaseline: Int = 0
    var openCacheMissBaseline: Int = 0

    /// 跨 row-rebuild sticky 的 per-stableId state。
    /// `Interaction.toggleState` 写入 + builder 读出 → 用户 toggle 跨内容更新仍保留。
    var stickyStates: [StableId: any Sendable] = [:]

    /// 当前悬停的 hover region —— 鼠标离开或进入新 region 时触发 onEnter/onExit。
    /// 见 `TranscriptController+Hit.updateHover(atDocumentPoint:)`。
    var currentHover: (key: HoverKey, exitHandler: @MainActor @Sendable (AnyRowContext) -> Void)?

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
        let stickySnapshot = stickyStates
        let engine = syntaxEngine
        let transcriptTheme = TranscriptTheme(markdown: mdTheme)

        if case .initialPaint = reason, openStartedAt != nil {
            openCacheHitBaseline = TranscriptPrepareCache.shared.hitCount
            openCacheMissBaseline = TranscriptPrepareCache.shared.missCount
        }

        let oldSigCount = lastEntriesSignature.count
        lastLayoutWidth = width
        lastEntriesSignature = signature
        lastThemeFingerprint = themeFingerprint

        switch reason {
        case .idle:
            return

        case .initialPaint:
            if let hint = scrollHint,
               let anchorIdx = entries.firstIndex(where: { $0.id == hint.entryId })
            {
                runViewportFirstAroundAnchor(
                    entries: entries,
                    anchorEntryIndex: anchorIdx,
                    anchorTopOffset: hint.topOffset,
                    theme: transcriptTheme, width: width,
                    stickyStates: stickySnapshot, engine: engine,
                    generation: generation, t0: t0)
            } else {
                runViewportFirstBottom(
                    entries: entries,
                    theme: transcriptTheme, width: width,
                    stickyStates: stickySnapshot, engine: engine,
                    generation: generation, t0: t0)
            }

        case .prependHistory:
            runFullDiffMerge(
                entries: entries,
                theme: transcriptTheme, width: width,
                stickyStates: stickySnapshot, engine: engine,
                generation: generation, t0: t0,
                scroll: anchorToCurrentTop() ?? .preserve,
                tag: "prepend")

        case .liveAppend:
            runLiveAppend(
                entries: entries,
                oldSigCount: oldSigCount,
                theme: transcriptTheme, width: width,
                stickyStates: stickySnapshot, engine: engine,
                generation: generation, t0: t0)

        case .update:
            runFullDiffMerge(
                entries: entries,
                theme: transcriptTheme, width: width,
                stickyStates: stickySnapshot, engine: engine,
                generation: generation, t0: t0,
                scroll: .preserve,
                tag: "update")
        }
    }

    func anchorToCurrentTop() -> TranscriptScrollIntent? {
        guard let tv = tableView, !rows.isEmpty,
              let clip = tv.enclosingScrollView?.contentView else { return nil }
        let rect = tv.rect(ofRow: 0)
        return .anchor(stableId: rows[0].stableId,
                       topOffset: rect.minY - clip.bounds.minY)
    }

    func captureScrollHint() -> SavedScrollAnchor? {
        guard let tv = tableView, !rows.isEmpty,
              let clip = tv.enclosingScrollView?.contentView else { return nil }

        let maxY = max(0, tv.bounds.height - clip.bounds.height)
        if clip.bounds.minY >= maxY - 2 { return nil }

        let visible = tv.rows(in: clip.bounds)
        guard visible.length > 0, visible.location >= 0,
              visible.location < rows.count else { return nil }
        let idx = visible.location
        let entryId = rows[idx].stableId.entryId
        let rect = tv.rect(ofRow: idx)
        return SavedScrollAnchor(
            entryId: entryId,
            topOffset: rect.minY - clip.bounds.minY)
    }

    // MARK: - Row-level reload

    func noteHeightOfRow(_ row: Int, animated: Bool = false) {
        guard let tableView, row >= 0, row < rows.count else { return }
        if animated {
            // 沿用调用方的 `NSAnimationContext`(典型:外层
            // `NSAnimationContext.runAnimationGroup` 设了 duration / timing),
            // NSTableView 用其参数走 builtin row-height animation。
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        } else {
            // 非动画路径在 nested group 里强制 duration = 0,避免污染外层
            // `NSAnimationContext`(否则会让外层正在跑的动画被瞬时打断)。
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            NSAnimationContext.endGrouping()
        }
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

        if let rv = tableView.rowView(atRow: row, makeIfNecessary: false) as? TranscriptRowView {
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

    // MARK: - Selection hooks

    func notifyRowSelectionChanged(index: Int) {
        guard let tableView, index >= 0, index < rows.count else { return }
        if let rv = tableView.rowView(atRow: index, makeIfNecessary: false) as? TranscriptRowView {
            rv.set(row: rows[index])
        }
    }

    func notifyRowSelectionCleared(stableId: StableId) {
        guard let tableView else { return }
        guard let idx = rows.firstIndex(where: { $0.stableId == stableId }) else { return }
        let cb = rows[idx].callbacks
        rows[idx].state = cb.clearingSelection(rows[idx].state)
        if let rv = tableView.rowView(atRow: idx, makeIfNecessary: false) as? TranscriptRowView {
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

    // MARK: - State / interaction dispatch (used by Hit + RowContext)

    /// 把 row 的 state 替换为 newState,跑 relayouted/full layout,刷新 row 高度 + 重绘。
    /// `Interaction.toggleState` / `.custom` handler 通过 `RowContext.applyState` 调入。
    ///
    /// `animated: true` 时 `noteHeightOfRow` 透传 animated,NSTableView 会沿用
    /// 调用方设置的 `NSAnimationContext.runAnimationGroup` duration 平滑过渡 row 高度。
    func applyState(stableId: StableId, newState: any Sendable, animated: Bool = false) {
        guard let idx = rows.firstIndex(where: { $0.stableId == stableId }) else { return }
        let cb = rows[idx].callbacks
        let theme = TranscriptTheme(markdown: theme ?? .default)
        let width = lastLayoutWidth
        rows[idx].state = newState
        stickyStates[stableId] = newState

        // Try fast path first.
        let fast = cb.relayouted(rows[idx].layout, newState, theme)
        if let new = fast {
            rows[idx].layout = new
            rows[idx].cachedSize = CGSize(width: width, height: new.cachedHeight)
        } else {
            let full = cb.layoutFull(rows[idx].content, newState, theme, width)
            rows[idx].layout = full
            rows[idx].cachedSize = CGSize(width: width, height: full.cachedHeight)
        }
        noteHeightOfRow(idx, animated: animated)
        if let tableView,
           let rv = tableView.rowView(atRow: idx, makeIfNecessary: false) as? TranscriptRowView {
            rv.set(row: rows[idx])
        }
    }

    /// 给 RowContext 的 `currentState` 用 —— 读当前 state。
    func currentState(stableId: StableId) -> any Sendable {
        guard let idx = rows.firstIndex(where: { $0.stableId == stableId }) else {
            // Row gone — return a benign placeholder. Callers check applyState
            // 是否成功(no-op when row absent),不会真依赖此值。
            return ()
        }
        return rows[idx].state
    }

    /// 给 RowContext 用 —— stableId 找不到 → no-op。
    func sideCar(stableId: StableId) -> any RowSideCar {
        guard let idx = rows.firstIndex(where: { $0.stableId == stableId }) else {
            return EmptyRowSideCar()
        }
        return rows[idx].sideCar
    }

    /// 构造 framework 注入给 handler 的 RowContext(type-erased)。
    func makeRowContext(stableId: StableId) -> AnyRowContext {
        let theme = TranscriptTheme(markdown: theme ?? .default)
        return AnyRowContext(
            stableId: stableId,
            cachedWidth: lastLayoutWidth,
            theme: theme,
            currentStateErased: { [weak self] in
                self?.currentState(stableId: stableId) ?? ()
            },
            applyStateErased: { [weak self] newState, animated in
                self?.applyState(stableId: stableId, newState: newState, animated: animated)
            },
            noteHeightOfRow: { [weak self] in
                guard let self,
                      let idx = self.rows.firstIndex(where: { $0.stableId == stableId }) else { return }
                self.noteHeightOfRow(idx)
            },
            redraw: { [weak self] in
                guard let self,
                      let idx = self.rows.firstIndex(where: { $0.stableId == stableId }) else { return }
                self.reloadRowView(at: idx, animated: false)
            },
            clearSelection: { [weak self] in
                self?.selectionController.clear()
                self?.redrawAllVisibleRows()
            },
            sideCarErased: { [weak self] in
                self?.sideCar(stableId: stableId) ?? EmptyRowSideCar()
            })
    }

    // MARK: - Resize

    private func isLayoutReady() -> Bool {
        return (tableView?.enclosingScrollView?.contentView.bounds.height ?? 0) > 0
    }

    func tableWidthChanged(_ rawNewWidth: CGFloat) {
        guard let tableView else { return }
        guard rawNewWidth > 0 else { return }

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
        let theme = TranscriptTheme(markdown: theme ?? .default)
        tableView.beginUpdates()
        NSAnimationContext.current.duration = 0
        var changed = IndexSet()
        for i in rows.indices where rows[i].cachedSize.width != width {
            let before = rows[i].cachedSize.height
            relayoutRow(at: i, width: width, theme: theme)
            if rows[i].cachedSize.height != before { changed.insert(i) }
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
        let theme = TranscriptTheme(markdown: theme ?? .default)
        let t0 = CFAbsoluteTimeGetCurrent()
        let visible = tableView.rows(in: clip.bounds)
        guard visible.length > 0, visible.location >= 0 else { return }

        tableView.beginUpdates()
        NSAnimationContext.current.duration = 0
        var changed = IndexSet()
        let end = min(visible.location + visible.length, rows.count)
        for i in max(0, visible.location)..<end {
            let before = rows[i].cachedSize.height
            relayoutRow(at: i, width: width, theme: theme)
            if rows[i].cachedSize.height != before { changed.insert(i) }
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
        let theme = TranscriptTheme(markdown: theme ?? .default)
        let t0 = CFAbsoluteTimeGetCurrent()
        tableView.beginUpdates()
        var changed = IndexSet()
        for i in rows.indices {
            let before = rows[i].cachedSize.height
            relayoutRow(at: i, width: width, theme: theme)
            if rows[i].cachedSize.height != before { changed.insert(i) }
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

    /// In-place re-layout of one row at a given width. Updates layout + cachedSize.
    func relayoutRow(at idx: Int, width: CGFloat, theme: TranscriptTheme) {
        guard idx >= 0, idx < rows.count else { return }
        let cb = rows[idx].callbacks
        let new = cb.layoutFull(rows[idx].content, rows[idx].state, theme, width)
        rows[idx].layout = new
        rows[idx].cachedSize = CGSize(width: width, height: new.cachedHeight)
    }

    // MARK: - Scroll anchor

    struct ScrollAnchor {
        let stableId: StableId
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
        return max(1, rows[row].cachedSize.height)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard row >= 0, row < rows.count else { return nil }
        let data = rows[row]
        let id = NSUserInterfaceItemIdentifier(data.identifier)
        let rowView: TranscriptRowView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? TranscriptRowView {
            rowView = reused
        } else {
            rowView = TranscriptRowView(frame: .zero)
            rowView.identifier = id
        }
        rowView.controller = self
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

    private func clampedRowLayoutWidth(from rawClipWidth: CGFloat) -> CGFloat {
        let maxW = TranscriptTheme(markdown: theme ?? .default).maxContentWidth
        return min(rawClipWidth, maxW)
    }

    func contentInset(forRow idx: Int, rowRect: CGRect) -> CGFloat {
        guard idx >= 0, idx < rows.count else { return 0 }
        return max(0, (rowRect.width - rows[idx].cachedSize.width) / 2)
    }
}

// MARK: - Diag helpers

extension TranscriptUpdateReason {
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
    var anchorStableId: StableId? {
        if case .anchor(let sid, _) = self { return sid }
        return nil
    }

    var anchorTopOffset: CGFloat? {
        if case .anchor(_, let top) = self { return top }
        return nil
    }
}

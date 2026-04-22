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

    /// 用户点 sidebar → `ChatHistoryView.task` 入口记录的时间戳。controller 在
    /// 首个 session-open 的 Phase 1 merge 完成时读这个值算 TTFP，emit 后清零
    /// —— 一次性指标，不会重复打印。
    var openStartedAt: CFAbsoluteTime?

    /// session-open 的 cache delta baseline。当 `openStartedAt` 被设置后首次
    /// setEntries 入口记录；Phase 2 merge 出口做 delta 算 hit/miss。
    private var openCacheHitBaseline: Int = 0
    private var openCacheMissBaseline: Int = 0

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

    /// Viewport-first 两阶段，对齐 Telegram `TableUpdateTransition`：
    /// - **Phase 1**（主线程同步）：prepare + layout 能填满 viewport 的 N 条
    ///   entries，立即 merge → 用户看到首屏（未高亮）。从哪一端走取决于 scroll
    ///   intent：`.bottom` 走末尾，否则走开头。
    /// - **Phase 2**（后台 Task）：prepare + layout 剩余 entries，并 highlight
    ///   所有 code block。回主线程：对 Phase 1 rows apply tokens（回填上色），
    ///   Phase 2 rows 走 diff（尾插 / 前插由 delta 形状决定）。
    ///
    /// Scroll intent 由 `computeScrollIntent` 依据 old↔new IDs delta 形状派生，
    /// 不进 `setEntries` 签名：外部调用点零改动。
    ///
    /// Short-circuit：entries id 列表 + theme 指纹都等价 → 立即返回。
    func setEntries(_ entries: [MessageEntry], themeChanged: Bool) {
        guard tableView != nil else { return }
        let mdTheme = theme ?? .default
        let themeFingerprint = mdTheme.fingerprint
        let signature = entries.map { $0.id }

        if signature == lastEntriesSignature, lastThemeFingerprint == themeFingerprint {
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

        // Let hover-prewarm read the actual width used by a live controller
        // instead of guessing a theme-level max.
        TranscriptPrepareCache.shared.recordObservedWidth(width)

        // Snapshot cache baseline for session-open metric (consumed by
        // `.bottom` path only; other intents don't correspond to "session open").
        if openStartedAt != nil {
            openCacheHitBaseline = TranscriptPrepareCache.shared.hitCount
            openCacheMissBaseline = TranscriptPrepareCache.shared.missCount
        }

        let oldSig = lastEntriesSignature

        // Fast-path: pure tail append. Theme unchanged + strict prefix.
        // Streaming 场景 99% 命中(新 assistant frame 都是新 UUID,整体追加)。
        if !themeChanged,
           lastThemeFingerprint == themeFingerprint,
           detectPureAppend(newIDs: signature) != nil
        {
            let appendedEntries = Array(entries.suffix(from: oldSig.count))
            lastLayoutWidth = width
            lastEntriesSignature = signature
            fastPathAppend(
                appendedEntries: appendedEntries,
                theme: transcriptTheme,
                width: width,
                expandedSnapshot: expandedSnapshot,
                engine: engine,
                generation: generation,
                t0: t0)
            return
        }

        // Decide scroll intent from delta shape **before** mutating
        // `lastEntriesSignature` —— `detectPurePrepend` 读 self.lastEntriesSignature，
        // 必须看到 old 值。
        let intent = computeScrollIntent(oldSig: oldSig, newSig: signature)

        lastLayoutWidth = width
        lastEntriesSignature = signature
        lastThemeFingerprint = themeFingerprint

        switch intent {
        case .bottom:
            runViewportFirstBottom(
                entries: entries,
                theme: transcriptTheme, width: width,
                expandedSnapshot: expandedSnapshot, engine: engine,
                generation: generation, t0: t0)

        case .anchor:
            // Prepend / 整体重排：tail 已在 self.rows，做 Phase 1 头部 walk 会把 tail
            // 误判成 delete。直接走一次 full-diff（bg prepare + 主线程 merge + 应用
            // anchor scroll），让 TranscriptDiff 一次性处理 insert/update/carry-over。
            runFullDiffMerge(
                entries: entries,
                theme: transcriptTheme, width: width,
                expandedSnapshot: expandedSnapshot, engine: engine,
                generation: generation, t0: t0,
                scroll: intent)

        case .preserve:
            // 典型场景：theme change / mid-array tool_result 更新。Phase 1 head walk
            // 对这些情况仍有价值（viewport-worth 先上屏），其余走 Phase 2。
            runViewportFirstHead(
                entries: entries,
                theme: transcriptTheme, width: width,
                expandedSnapshot: expandedSnapshot, engine: engine,
                generation: generation, t0: t0,
                scroll: intent)
        }
    }

    /// `.anchor` / 通用 full-diff 路径：后台 prepare 全量 + highlight，主线程做一
    /// 次性 `TranscriptDiff.compute` 合并，应用 scroll intent。**不做 Phase 1
    /// 拆分**——对 prepend 场景而言，tail 已在 self.rows，一次性 diff 更干净。
    private func runFullDiffMerge(
        entries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime,
        scroll: TranscriptScrollIntent
    ) {
        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tPrepStart = CFAbsoluteTimeGetCurrent()
            var items = TranscriptRowBuilder.prepareAll(
                entries: entries,
                theme: transcriptTheme,
                width: width,
                expandedUserBubbles: expandedSnapshot)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            let (hlMs, codeBlockCount, _) = await Self.applyHighlightTokens(
                to: &items, theme: transcriptTheme, width: width, engine: engine)
            if Task.isCancelled { return }
            let tHlDone = CFAbsoluteTimeGetCurrent()

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()

                let newRows = items.map { self.row(from: $0, theme: transcriptTheme) }
                let transition = TranscriptDiff.compute(
                    old: self.rows, new: newRows, animated: false)
                for row in transition.finalRows {
                    if let u = row as? UserBubbleRow {
                        u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
                    }
                    row.makeSize(width: width)
                }
                self.merge(with: transition, scroll: scroll)

                let liveIds = Set(self.rows.map { $0.stableId })
                self.expandedUserBubbles.formIntersection(liveIds)
                let tMergeDone = CFAbsoluteTimeGetCurrent()

                let prepMs = Int((tPrepDone - tPrepStart) * 1000)
                let bgMs = Int((tHlDone - tPrepStart) * 1000)
                let mergeMs = Int((tMergeDone - tMergeStart) * 1000)
                let totalMs = Int((tMergeDone - t0) * 1000)
                appLog(.info, "TranscriptController",
                    "setEntries full-diff entries=\(entries.count) rows=\(newRows.count) "
                    + "(+\(transition.inserted.count) / ~\(transition.updated.count) / -\(transition.deleted.count)) "
                    + "prepare=\(prepMs) bg=\(bgMs)(hl=\(hlMs)ms code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) total=\(totalMs)ms width=\(Int(width)) "
                    + "scroll=\(scroll.logTag)")
            }
        }
    }

    // MARK: - Scroll intent derivation

    /// 根据 old↔new IDs delta 形状派生 scroll intent。
    ///
    /// | 形状                              | intent        |
    /// | --------------------------------- | ------------- |
    /// | old 空, new 非空                  | `.bottom`     |
    /// | old 是 new 的严格后缀 (pure prepend) | `.anchor(...)` |
    /// | 其它 (theme 变 / tool_result 更新)  | `.preserve`   |
    ///
    /// 说明：pure append 已在 fast-path 消化，此处不再涉及。
    private func computeScrollIntent(
        oldSig: [UUID], newSig: [UUID]
    ) -> TranscriptScrollIntent {
        // 首次打开 session。
        if oldSig.isEmpty, !newSig.isEmpty {
            return .bottom
        }
        // pure prepend：old 是 new 的严格后缀。
        if !oldSig.isEmpty,
           detectPurePrepend(newIDs: newSig) != nil,
           let anchor = captureTopVisibleAnchor()
        {
            return .anchor(stableId: anchor.stableId, topOffset: anchor.topOffset)
        }
        return .preserve
    }

    /// 取 rows[0] 的 (stableId, topOffset)—— Phase B prepend / loaded 合并前
    /// capture。容错：rows 空 / clipView 缺失 → nil（调用点降级为 `.preserve`）。
    private func captureTopVisibleAnchor() -> (stableId: AnyHashable, topOffset: CGFloat)? {
        guard let tv = tableView, !rows.isEmpty,
              let clip = tv.enclosingScrollView?.contentView else { return nil }
        let rect = tv.rect(ofRow: 0)
        return (rows[0].stableId, rect.minY - clip.bounds.minY)
    }

    // MARK: - Viewport-first pipelines

    /// Viewport-first head pipeline：Phase 1 从 entries[0] 向后走至填满 viewport，
    /// Phase 2 追加剩余 + highlight 全部。`.preserve` / `.anchor(...)` 两种 scroll
    /// intent 复用此路径（Phase 2 merge 结束时应用 scroll）。
    private func runViewportFirstHead(
        entries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime,
        scroll: TranscriptScrollIntent
    ) {
        let budget = phase1Budget()

        // ── Phase 1：head，主线程同步 ──────────────────────────────────────
        let phase1Walk = TranscriptRowBuilder.prepareBounded(
            entries: entries,
            theme: transcriptTheme,
            width: width,
            expandedUserBubbles: expandedSnapshot,
            minAccumulatedHeight: budget.height)
        let phase1EntryCount = phase1Walk.consumedEntryCount
        let phase1Rows = phase1Walk.items.map { self.row(from: $0, theme: transcriptTheme) }

        let phase1Transition = TranscriptDiff.compute(
            old: rows, new: phase1Rows, animated: false)
        for row in phase1Transition.finalRows {
            if let u = row as? UserBubbleRow {
                u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
            }
            row.makeSize(width: width)
        }
        // Phase 1 本身不做 scroll —— `.anchor` 的位置感觉要等 Phase 2 合并完整才对。
        self.merge(with: phase1Transition, scroll: .preserve)
        let tPhase1Done = CFAbsoluteTimeGetCurrent()
        let phase1Ms = Int((tPhase1Done - t0) * 1000)

        let phase1Items = phase1Walk.items
        let remainingEntries = Array(entries.suffix(from: phase1EntryCount))

        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tPrepStart = CFAbsoluteTimeGetCurrent()
            let phase2PreparedOnly = TranscriptRowBuilder.prepareAll(
                entries: remainingEntries,
                theme: transcriptTheme,
                width: width,
                expandedUserBubbles: expandedSnapshot)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            var combinedItems = phase1Items + phase2PreparedOnly
            let (hlMs, codeBlockCount, tokensByStableId) =
                await Self.applyHighlightTokens(
                    to: &combinedItems,
                    theme: transcriptTheme,
                    width: width,
                    engine: engine)
            if Task.isCancelled { return }
            let tHlDone = CFAbsoluteTimeGetCurrent()

            let updatedPhase2 = Array(combinedItems.suffix(from: phase1Items.count))

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()

                self.backfillHighlightTokens(
                    tokensByStableId: tokensByStableId, width: width)

                // Phase 2 rows：走 diff 正常 insert/update 路径。
                let phase2Rows = updatedPhase2.map { self.row(from: $0, theme: transcriptTheme) }
                let newFullRows = self.rows + phase2Rows
                let phase2Transition = TranscriptDiff.compute(
                    old: self.rows, new: newFullRows, animated: false)
                for row in phase2Transition.finalRows {
                    if let u = row as? UserBubbleRow {
                        u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
                    }
                    row.makeSize(width: width)
                }
                self.merge(with: phase2Transition, scroll: scroll)

                let liveIds = Set(self.rows.map { $0.stableId })
                self.expandedUserBubbles.formIntersection(liveIds)
                let tMergeDone = CFAbsoluteTimeGetCurrent()

                let prepMs = Int((tPrepDone - tPrepStart) * 1000)
                let bgMs = Int((tHlDone - tPrepStart) * 1000)
                let mergeMs = Int((tMergeDone - tMergeStart) * 1000)
                let totalMs = Int((tMergeDone - t0) * 1000)
                let reusedCount = phase2Transition.finalRows.count
                    - phase2Transition.inserted.count - phase2Transition.updated.count
                appLog(.info, "TranscriptController",
                    "setEntries head "
                    + "TTFP=\(phase1Ms)ms full=\(totalMs)ms "
                    + "phase1=\(phase1EntryCount)(rows=\(phase1Rows.count)) "
                    + "phase2=\(remainingEntries.count) "
                    + "(+\(phase2Transition.inserted.count) / ~\(phase2Transition.updated.count) / -\(phase2Transition.deleted.count) / reused=\(reusedCount)) "
                    + "prepare=\(prepMs) bg=\(bgMs)(hl=\(hlMs)ms code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) width=\(Int(width)) "
                    + "scroll=\(scroll.logTag) budget=\(budget.tag)")
            }
        }
    }

    /// Viewport-first bottom pipeline：Phase 1 从 entries 尾部反向走至填满
    /// viewport，立即挂载末尾 N 条并 scroll 到底部。Phase 2 前插前缀 entries，
    /// scroll 切到 `.anchor(rows[0])` 保住首屏视觉位置。
    private func runViewportFirstBottom(
        entries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        let budget = phase1Budget()

        // ── Phase 1：tail，主线程同步 ──────────────────────────────────────
        let phase1Walk = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: transcriptTheme,
            width: width,
            expandedUserBubbles: expandedSnapshot,
            minAccumulatedHeight: budget.height)
        let phase1StartIndex = phase1Walk.phase1StartIndex
        let phase1Rows = phase1Walk.items.map { self.row(from: $0, theme: transcriptTheme) }

        // Phase 1 是末尾段，但挂载时我们还没有 prefix 行——rows 在 Phase 1
        // 结束时视作完整"entries[phase1StartIndex...]"；到 Phase 2 再前插。
        let phase1Transition = TranscriptDiff.compute(
            old: rows, new: phase1Rows, animated: false)
        for row in phase1Transition.finalRows {
            if let u = row as? UserBubbleRow {
                u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
            }
            row.makeSize(width: width)
        }
        self.merge(with: phase1Transition, scroll: .bottom)
        let tPhase1Done = CFAbsoluteTimeGetCurrent()
        let phase1Ms = Int((tPhase1Done - t0) * 1000)
        let openStart = self.openStartedAt    // 可能 nil (非 session-open 首次打开)
        let openCacheHitBase = self.openCacheHitBaseline
        let openCacheMissBase = self.openCacheMissBaseline
        let openEntryCount = entries.count
        let openPhase1Rows = phase1Rows.count
        let openBudgetTag = budget.tag
        let openWidth = Int(width)

        let phase1Items = phase1Walk.items
        let prefixEntries = Array(entries.prefix(phase1StartIndex))

        // 若 prefix 为空（entries 整体都够塞进 viewport）Phase 2 仍跑是为了
        // 对 Phase 1 rows 做 highlight backfill。保持管线一致。
        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tPrepStart = CFAbsoluteTimeGetCurrent()
            let prefixPreparedOnly = TranscriptRowBuilder.prepareAll(
                entries: prefixEntries,
                theme: transcriptTheme,
                width: width,
                expandedUserBubbles: expandedSnapshot)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            // 合并进一次 highlightBatch。顺序：prefix + phase1（forward-order 合并）。
            var combinedItems = prefixPreparedOnly + phase1Items
            let (hlMs, codeBlockCount, tokensByStableId) =
                await Self.applyHighlightTokens(
                    to: &combinedItems,
                    theme: transcriptTheme,
                    width: width,
                    engine: engine)
            if Task.isCancelled { return }
            let tHlDone = CFAbsoluteTimeGetCurrent()

            // colored prefix 在 combinedItems 的前部。
            let coloredPrefix = Array(combinedItems.prefix(prefixPreparedOnly.count))

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()

                self.backfillHighlightTokens(
                    tokensByStableId: tokensByStableId, width: width)

                // prefix 前插 scroll intent：anchor 到当前 rows[0]（末尾首行）
                let anchor = self.captureTopVisibleAnchor()
                let scroll: TranscriptScrollIntent = anchor.map {
                    .anchor(stableId: $0.stableId, topOffset: $0.topOffset)
                } ?? .preserve

                let prefixRows = coloredPrefix.map {
                    self.row(from: $0, theme: transcriptTheme)
                }
                let newFullRows = prefixRows + self.rows
                let phase2Transition = TranscriptDiff.compute(
                    old: self.rows, new: newFullRows, animated: false)
                for row in phase2Transition.finalRows {
                    if let u = row as? UserBubbleRow {
                        u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
                    }
                    row.makeSize(width: width)
                }
                self.merge(with: phase2Transition, scroll: scroll)

                let liveIds = Set(self.rows.map { $0.stableId })
                self.expandedUserBubbles.formIntersection(liveIds)
                let tMergeDone = CFAbsoluteTimeGetCurrent()

                let prepMs = Int((tPrepDone - tPrepStart) * 1000)
                let bgMs = Int((tHlDone - tPrepStart) * 1000)
                let mergeMs = Int((tMergeDone - tMergeStart) * 1000)
                let totalMs = Int((tMergeDone - t0) * 1000)
                let reusedCount = phase2Transition.finalRows.count
                    - phase2Transition.inserted.count - phase2Transition.updated.count
                appLog(.info, "TranscriptController",
                    "setEntries bottom "
                    + "TTFP=\(phase1Ms)ms full=\(totalMs)ms "
                    + "phase1=\(entries.count - phase1StartIndex)(rows=\(phase1Rows.count)) "
                    + "phase2=\(prefixEntries.count) "
                    + "(+\(phase2Transition.inserted.count) / ~\(phase2Transition.updated.count) / -\(phase2Transition.deleted.count) / reused=\(reusedCount)) "
                    + "prepare=\(prepMs) bg=\(bgMs)(hl=\(hlMs)ms code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) width=\(Int(width)) "
                    + "scroll=\(scroll.logTag) budget=\(budget.tag)")

                // session-open 一次性 metric（TTFP 从用户点击 sidebar 起计，
                // 而非 setEntries 入口；包含 loadHistory 的 I/O）。
                if let openStart {
                    let ttfpMs = Int((tPhase1Done - openStart) * 1000)
                    let fullMs = Int((tMergeDone - openStart) * 1000)
                    let snapshot = OpenMetrics.Snapshot(
                        ttfpMs: ttfpMs,
                        fullMs: fullMs,
                        entryCount: openEntryCount,
                        phase1Rows: openPhase1Rows,
                        cacheHit: TranscriptPrepareCache.shared.hitCount - openCacheHitBase,
                        cacheMiss: TranscriptPrepareCache.shared.missCount - openCacheMissBase,
                        width: openWidth,
                        viewportTag: openBudgetTag,
                        scrollTag: "bottom")
                    appLog(.info, "TranscriptController", OpenMetrics.format(snapshot))
                    self.openStartedAt = nil
                }
            }
        }
    }

    /// 把 Phase 2 highlight 完成后 tokens 回写到已挂载的 rows。
    ///
    /// 主线程专属。逻辑：走 self.rows，对 stableId 能在 `tokensByStableId`
    /// 找到的 assistant row `apply(codeTokens:)` + makeSize + 刷 rowView。
    private func backfillHighlightTokens(
        tokensByStableId: [AnyHashable: [Int: [SyntaxToken]]],
        width: CGFloat
    ) {
        var changed: IndexSet = []
        for (idx, row) in self.rows.enumerated() {
            guard let a = row as? AssistantMarkdownRow,
                  let tokens = tokensByStableId[a.stableId] else { continue }
            a.apply(codeTokens: tokens)
            a.makeSize(width: width)
            changed.insert(idx)
        }
        guard !changed.isEmpty else { return }
        self.tableView?.noteHeightOfRows(withIndexesChanged: changed)
        for idx in changed {
            if let rv = self.tableView?.rowView(atRow: idx, makeIfNecessary: false)
                as? TranscriptRowView {
                rv.set(row: self.rows[idx])
            }
        }
    }

    // MARK: - Phase 1 budget

    private struct Phase1Budget {
        let height: CGFloat
        /// `"ok"` / `"fallback-clip"` / `"fallback-table"` / `"fallback-const"` —
        /// 进入日志帮助线上回归判断 Phase 1 的 height 是来自真实 viewport 还是兜底。
        let tag: String
    }

    /// viewport height 兜底。首次 `updateNSView` 时 clipView 可能尚未 tile 稳定，
    /// `bounds.height` 读到 0 会让 `prepareBounded(Tail)` 第一条就满足阈值立即返回，
    /// 只渲出 1 条。不同 fallback source 打 tag 以便观察。
    private func phase1Budget() -> Phase1Budget {
        let clip = tableView?.enclosingScrollView?.contentView.bounds.height ?? 0
        if clip > 0 {
            return Phase1Budget(height: clip * 1.2, tag: "ok")
        }
        let tableH = tableView?.bounds.height ?? 0
        if tableH > 0 {
            return Phase1Budget(height: tableH * 1.2, tag: "fallback-table")
        }
        // 最终 fallback：400pt ≈ 可视 6-8 行，够打满一个标准 message。
        return Phase1Budget(height: 400, tag: "fallback-const")
    }

    // MARK: - Fast-path: pure append

    #if DEBUG
    /// Test hooks — let `FastPathDetectionTests` reach internal state without
    /// exposing it module-wide.
    func _testHook_setLastEntriesSignature(_ ids: [UUID]) {
        self.lastEntriesSignature = ids
    }
    func _testHook_detectPureAppend(newIDs: [UUID]) -> [UUID]? {
        detectPureAppend(newIDs: newIDs)
    }
    #endif

    /// 如果 `lastEntriesSignature` 是 `newIDs` 的**严格前缀**,返回尾部新增的
    /// 原始 IDs(caller 再从 entries 里截取同样位置的 MessageEntry)。
    /// 否则返回 nil(走 slow path)。
    ///
    /// - 前缀必须 **完全相等**(包括顺序),长度 N 严格小于新 IDs 长度
    /// - 任何中间插入、删除、重排、唯一性改变都会导致 nil
    /// - theme 改动由调用点外层 gate 隔离,这里只看 IDs
    private func detectPureAppend(newIDs: [UUID]) -> [UUID]? {
        guard newIDs.count > lastEntriesSignature.count else { return nil }
        for (i, oldID) in lastEntriesSignature.enumerated() where newIDs[i] != oldID {
            return nil
        }
        return Array(newIDs.suffix(from: lastEntriesSignature.count))
    }

    #if DEBUG
    func _testHook_detectPurePrepend(newIDs: [UUID]) -> [UUID]? {
        detectPurePrepend(newIDs: newIDs)
    }
    #endif

    /// `detectPureAppend` 的对称版。如果 `lastEntriesSignature` 是 `newIDs` 的
    /// **严格后缀**(中间没插入、没重排、仅头部追加),返回头部新增的 IDs。
    /// 否则 nil。Phase B loaded merge 时用来驱动 `.anchor` scroll intent。
    private func detectPurePrepend(newIDs: [UUID]) -> [UUID]? {
        guard newIDs.count > lastEntriesSignature.count else { return nil }
        let prefixCount = newIDs.count - lastEntriesSignature.count
        for (i, oldID) in lastEntriesSignature.enumerated()
            where newIDs[prefixCount + i] != oldID {
            return nil
        }
        return Array(newIDs.prefix(prefixCount))
    }

    /// Fast-path: 只对追加的 entries 做 prepare + highlight + tail insert。
    /// 完全不动已挂载的 rows;diff 仅涉及尾部 k 行,极快。
    private func fastPathAppend(
        appendedEntries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Prepare + layout(cached 路径,非常快)。
            var items = TranscriptRowBuilder.prepareAll(
                entries: appendedEntries,
                theme: transcriptTheme,
                width: width,
                expandedUserBubbles: expandedSnapshot)
            if Task.isCancelled { return }

            let (hlMs, codeBlockCount, _) = await Self.applyHighlightTokens(
                to: &items, theme: transcriptTheme, width: width, engine: engine)
            if Task.isCancelled { return }

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()
                let appendedRows = items.map { self.row(from: $0, theme: transcriptTheme) }

                // Sync expand for 新 user rows(应已由 prepareAll 设置,但幂等 OK)。
                for row in appendedRows {
                    if let u = row as? UserBubbleRow {
                        u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
                    }
                    row.makeSize(width: width)
                }

                // 直接构造 insert-only transition,跳过 TranscriptDiff(无需 diff)。
                let insertions = appendedRows.enumerated().map {
                    (self.rows.count + $0.offset, $0.element)
                }
                let transition = TranscriptUpdateTransition(
                    deleted: [],
                    inserted: insertions,
                    updated: [],
                    finalRows: self.rows + appendedRows,
                    animated: false)
                self.merge(with: transition, scroll: .preserve)

                let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let mergeMs = Int((CFAbsoluteTimeGetCurrent() - tMergeStart) * 1000)
                appLog(.info, "TranscriptController",
                    "setEntries fast-path append=\(appendedEntries.count) rows=\(appendedRows.count) "
                    + "total=\(totalMs)ms hl=\(hlMs)ms(code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) width=\(Int(width))")
            }
        }
    }

    // MARK: - Prepared → Row

    /// 把 `TranscriptPreparedItem`(Sendable,off-main 构造)包成 `TranscriptRow`
    /// 实例(@MainActor)。O(1)——只是属性赋值,不做 CoreText。
    private func row(from item: TranscriptPreparedItem, theme: TranscriptTheme) -> TranscriptRow {
        switch item {
        case .assistant(let prepared, let layout):
            let r = AssistantMarkdownRow(prepared: prepared, theme: theme)
            r.applyLayout(layout)
            return r
        case .user(let prepared, let layout, let isExpanded):
            let r = UserBubbleRow(prepared: prepared, theme: theme)
            r.isExpanded = isExpanded
            r.applyLayout(layout)
            return r
        case .placeholder(let prepared, let layout):
            let r = PlaceholderRow(prepared: prepared, theme: theme)
            r.applyLayout(layout)
            return r
        }
    }

    // MARK: - Highlight pipeline (nonisolated)

    /// 收集 `items` 中所有 assistant 的 code block → 一次 highlightBatch →
    /// 对命中 token 的 item 重建 prebuilt(用彩色 attr)+ 再排版。修改 `items`
    /// in-place。
    ///
    /// 返回：
    /// - `hlMs`:纯 highlightBatch 耗时
    /// - `codeBlockCount`:本批次 code block 总数
    /// - `tokensByStableId`:stableId → (segIndex → tokens),给主线程回填已挂载
    ///   的 Phase 1 row 用。
    ///
    /// 完全 nonisolated——engine.load / highlightBatch 内部自己处理线程切换。
    nonisolated private static func applyHighlightTokens(
        to items: inout [TranscriptPreparedItem],
        theme: TranscriptTheme,
        width: CGFloat,
        engine: SyntaxHighlightEngine?
    ) async -> (hlMs: Int, codeBlockCount: Int, tokensByStableId: [AnyHashable: [Int: [SyntaxToken]]]) {
        // 收集请求 + 记 (itemIndex, segmentIndex) → batch 位置。跳过
        // 已高亮过的 item(通常来自 cache hit) — 避免重复 highlight。
        var requests: [(code: String, language: String?)] = []
        var routing: [(itemIndex: Int, segmentIndex: Int)] = []
        for (itemIdx, item) in items.enumerated() {
            guard case let .assistant(prepared, _) = item,
                  !prepared.hasHighlight else { continue }
            for (segIdx, seg) in prepared.parsedDocument.segments.enumerated() {
                if case .codeBlock(let block) = seg {
                    requests.append((block.code, block.language))
                    routing.append((itemIdx, segIdx))
                }
            }
        }
        guard !requests.isEmpty, let engine else {
            return (0, requests.count, [:])
        }
        if Task.isCancelled { return (0, requests.count, [:]) }

        await engine.load()
        if Task.isCancelled { return (0, requests.count, [:]) }

        let t0 = CFAbsoluteTimeGetCurrent()
        let batch = await engine.highlightBatch(requests)
        let hlMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard batch.count == routing.count else {
            appLog(.warning, "TranscriptController",
                "highlight batch size mismatch: got \(batch.count) expected \(routing.count)")
            return (hlMs, requests.count, [:])
        }

        // 按 itemIndex 聚合:itemIndex → (segIndex → tokens)。
        var byItem: [Int: [Int: [SyntaxToken]]] = [:]
        for (i, route) in routing.enumerated() {
            byItem[route.itemIndex, default: [:]][route.segmentIndex] = batch[i]
        }

        // 对每个 assistant item:用 tokens 重建 prebuilt + 再 layout,in-place 替换。
        // 同时 collect stableId → tokens map 给主线程用。
        var tokensByStableId: [AnyHashable: [Int: [SyntaxToken]]] = [:]
        for (itemIdx, segTokens) in byItem {
            guard case let .assistant(prepared, _) = items[itemIdx] else { continue }
            let newPrebuilt = MarkdownRowPrebuilder.build(
                document: prepared.parsedDocument,
                theme: theme,
                codeTokens: segTokens)
            let newPrepared = AssistantPrepared(
                source: prepared.source,
                parsedDocument: prepared.parsedDocument,
                prebuilt: newPrebuilt,
                stable: prepared.stable,
                contentHash: prepared.contentHash,
                hasHighlight: true)
            let newLayout = TranscriptPrepare.layoutAssistant(
                prebuilt: newPrebuilt, theme: theme, width: width)
            let newItem: TranscriptPreparedItem = .assistant(newPrepared, newLayout)
            items[itemIdx] = newItem
            tokensByStableId[prepared.stable] = segTokens

            // Write back to the shared cache as a colored entry. Subsequent
            // `prepareAll` walks on the same (contentHash, widthBucket) key
            // will hit this colored version and skip both prepare and
            // highlight.
            TranscriptPrepareCache.shared.put(
                newItem.cacheKey(width: width), newItem)
        }
        return (hlMs, requests.count, tokensByStableId)
    }

    // MARK: - merge

    /// 把 transition 应用到 tableView。主线程。
    ///
    /// `scroll` 在 `beginUpdates`/`endUpdates` **之外** 应用——AppKit 的 batch
    /// updates 是 animation transaction，不是 geometry transaction；期间读
    /// `rect(ofRow:)` 会拿到陈旧值。Telegram macOS 的 `saveScrollState` 同理也
    /// 在 non-live 路径上外部执行。
    private func merge(
        with transition: TranscriptUpdateTransition,
        scroll: TranscriptScrollIntent
    ) {
        guard let tableView else { return }

        let anim: NSTableView.AnimationOptions = transition.animated ? .effectFade : []
        if !transition.animated {
            NSAnimationContext.current.duration = 0
        }

        // 空 transition 保护——但 scroll 仍可能要应用（纯 scroll 请求的场景）。
        if transition.isEmpty, rows.count == transition.finalRows.count,
           zip(rows, transition.finalRows).allSatisfy({ $0 === $1 }) {
            applyScrollIntent(scroll)
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

        applyScrollIntent(scroll)
    }

    /// 依据 intent 设置 clipView origin。在 `endUpdates` 之后调用——此时 rows
    /// 与 tableView geometry 都已落定，`rect(ofRow:)` 是最新值。
    private func applyScrollIntent(_ intent: TranscriptScrollIntent) {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return }
        switch intent {
        case .preserve:
            return
        case .bottom:
            let maxY = max(0, tableView.bounds.height - clip.bounds.height)
            guard abs(maxY - clip.bounds.minY) > 0.5 else { return }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: maxY))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        case let .anchor(stableId, topOffset):
            guard let idx = rows.firstIndex(where: { $0.stableId == stableId }) else {
                return
            }
            let newRect = tableView.rect(ofRow: idx)
            let newY = newRect.minY - topOffset
            let maxY = max(0, tableView.bounds.height - clip.bounds.height)
            let clamped = max(0, min(newY, maxY))
            guard abs(clamped - clip.bounds.minY) > 0.5 else { return }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clamped))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
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

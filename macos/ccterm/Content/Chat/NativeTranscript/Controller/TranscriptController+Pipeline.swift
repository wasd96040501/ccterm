import AppKit

/// `setEntries` 按 `TranscriptUpdateReason` 分发的 4 条 pipeline + 共用助手
/// (Phase 1 budget / highlight 回灌 / Prepared→Row / nonisolated highlight
/// batch)。runner 们读写 controller 上跨文件可见的 `setEntriesGeneration` /
/// `activePreprocessTask` / `openCacheHit/MissBaseline` / `expandedUserBubbles`
/// 等状态;主文件里这些字段声明为 internal。
extension TranscriptController {
    // MARK: - Pipelines

    /// 全量 diff merge。后台 prepare + highlight，回主线程一次性 `TranscriptDiff`
    /// 合并并应用给定 scroll intent。`.prependHistory` / `.update` 共用。
    func runFullDiffMerge(
        entries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime,
        scroll: TranscriptScrollIntent,
        tag: String
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
                self.syncExpansionAndSize(transition.finalRows, width: width)
                self.merge(with: transition, scroll: scroll)
                self.logVisualSnapshot(
                    tag: "\(tag)-merged",
                    expectedAnchorStableId: scroll.anchorStableId,
                    expectedTopOffset: scroll.anchorTopOffset)

                let liveIds = Set(self.rows.map { $0.stableId })
                self.expandedUserBubbles.formIntersection(liveIds)
                let tMergeDone = CFAbsoluteTimeGetCurrent()

                let prepMs = Int((tPrepDone - tPrepStart) * 1000)
                let bgMs = Int((tHlDone - tPrepStart) * 1000)
                let mergeMs = Int((tMergeDone - tMergeStart) * 1000)
                let totalMs = Int((tMergeDone - t0) * 1000)
                appLog(.info, "TranscriptController",
                    "setEntries \(tag) entries=\(entries.count) rows=\(newRows.count) "
                    + "(+\(transition.inserted.count) / ~\(transition.updated.count) / -\(transition.deleted.count)) "
                    + "prepare=\(prepMs) bg=\(bgMs)(hl=\(hlMs)ms code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) total=\(totalMs)ms width=\(Int(width)) "
                    + "scroll=\(scroll.logTag)")
            }
        }
    }

    /// `.initialPaint` pipeline：Phase 1 从 entries 尾部反向走至填满 viewport，
    /// 立即挂载末尾 N 条并 scroll 到底部。Phase 2 前插前缀 entries，
    /// scroll 切到 `.anchor(rows[0])` 保住首屏视觉位置。
    func runViewportFirstBottom(
        entries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        let budget = phase1Budget()

        let phase1Walk = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: transcriptTheme,
            width: width,
            expandedUserBubbles: expandedSnapshot,
            minAccumulatedHeight: budget.height)
        let phase1StartIndex = phase1Walk.phase1StartIndex
        let phase1Rows = phase1Walk.items.map { self.row(from: $0, theme: transcriptTheme) }

        let phase1Transition = TranscriptDiff.compute(
            old: rows, new: phase1Rows, animated: false)
        self.syncExpansionAndSize(phase1Transition.finalRows, width: width)
        self.merge(with: phase1Transition, scroll: .bottom)
        self.logVisualSnapshot(
            tag: "bottom-phase1-merged",
            expectedAnchorStableId: nil,
            expectedTopOffset: nil)
        let tPhase1Done = CFAbsoluteTimeGetCurrent()
        let phase1Ms = Int((tPhase1Done - t0) * 1000)
        let openStart = self.openStartedAt
        let openCacheHitBase = self.openCacheHitBaseline
        let openCacheMissBase = self.openCacheMissBaseline
        let openEntryCount = entries.count
        let openPhase1Rows = phase1Rows.count
        let openBudgetTag = budget.tag
        let openWidth = Int(width)

        let phase1Items = phase1Walk.items
        let prefixEntries = Array(entries.prefix(phase1StartIndex))

        // 即便 prefix 为空（整个 entries 都塞进 viewport）Phase 2 仍跑——给
        // Phase 1 rows 做 highlight backfill。保持管线一致。
        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tPrepStart = CFAbsoluteTimeGetCurrent()
            let prefixPreparedOnly = TranscriptRowBuilder.prepareAll(
                entries: prefixEntries,
                theme: transcriptTheme,
                width: width,
                expandedUserBubbles: expandedSnapshot)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            var combinedItems = prefixPreparedOnly + phase1Items
            let (hlMs, codeBlockCount, tokensByStableId) =
                await Self.applyHighlightTokens(
                    to: &combinedItems,
                    theme: transcriptTheme,
                    width: width,
                    engine: engine)
            if Task.isCancelled { return }
            let tHlDone = CFAbsoluteTimeGetCurrent()

            let coloredPrefix = Array(combinedItems.prefix(prefixPreparedOnly.count))

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()

                self.backfillHighlightTokens(
                    tokensByStableId: tokensByStableId, width: width)
                self.logVisualSnapshot(
                    tag: "bottom-post-backfill",
                    expectedAnchorStableId: nil,
                    expectedTopOffset: nil)

                // prefix 前插 → anchor 到当前 rows[0]（末尾首行），保住 Phase 1
                // 建立的视觉位置。Telegram `saveVisible(.upper, false)` 等价。
                let scroll: TranscriptScrollIntent =
                    self.anchorToCurrentTop() ?? .preserve

                let prefixRows = coloredPrefix.map {
                    self.row(from: $0, theme: transcriptTheme)
                }
                let newFullRows = prefixRows + self.rows
                let phase2Transition = TranscriptDiff.compute(
                    old: self.rows, new: newFullRows, animated: false)
                self.syncExpansionAndSize(phase2Transition.finalRows, width: width)
                self.merge(with: phase2Transition, scroll: scroll)
                self.logVisualSnapshot(
                    tag: "bottom-phase2-merged",
                    expectedAnchorStableId: scroll.anchorStableId,
                    expectedTopOffset: scroll.anchorTopOffset)

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
                    "setEntries initialPaint "
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

    /// `.initialPaint` with scroll hint：围绕 anchor entry 展开 Phase 1，scroll
    /// 锚到 `hint.stableId + hint.topOffset` 保住离开时的视觉位置。Phase 2 补齐
    /// 左右两侧 entries + highlight backfill，再 anchor 一次保住位置。
    ///
    /// 对齐 Telegram macOS `prepareEntries` 里 `scrollToItem == .top(id:...)` +
    /// `firstTransition` + `.saveVisible(.upper, false)` 的两段式。
    func runViewportFirstAroundAnchor(
        entries: [MessageEntry],
        anchorEntryIndex: Int,
        anchorTopOffset: CGFloat,
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        let budget = phase1Budget()

        // Phase 1 的双侧 budget 必须支撑 `.anchor(topOffset)` 的 scroll 目标：
        // clipY = Y_a - topOffset 必须落在 [0, tableH - clipH] 内。
        // - 上方需要 `max(0, topOffset)`：anchor 在 viewport 内正向偏下时，需要
        //   anchor 上方对应高度的 entries 支撑（否则 clipY < 0 被 clamp）。
        // - 下方需要 `max(0, clipH - topOffset)`：anchor 起到 viewport 底的部分
        //   （含 anchor 自身），不够就 maxY 太小、clipY 被 clamp 到底。
        // 两侧各加 `budget.height - clipH`（默认 20% clipH）做 elastic/paging 余量。
        let clipH = tableView?.enclosingScrollView?.contentView.bounds.height ?? 0
        let margin = max(0, budget.height - clipH)
        let aboveBudget = max(0, anchorTopOffset) + margin
        let belowBudget = max(0, clipH - anchorTopOffset) + margin

        let phase1Walk = TranscriptRowBuilder.prepareBoundedAround(
            entries: entries,
            anchorEntryIndex: anchorEntryIndex,
            theme: transcriptTheme,
            width: width,
            expandedUserBubbles: expandedSnapshot,
            aboveMinHeight: aboveBudget,
            belowMinHeight: belowBudget)
        let phase1Rows = phase1Walk.items.map { self.row(from: $0, theme: transcriptTheme) }

        // Phase 1 merge：把 anchor 区段挂上去。stableId 还是原 entry.id，
        // 和 hint.stableId 对得上 → applyScrollIntent 能找到该行并对齐 topOffset。
        let phase1Transition = TranscriptDiff.compute(
            old: rows, new: phase1Rows, animated: false)
        self.syncExpansionAndSize(phase1Transition.finalRows, width: width)
        // 用 phase1 items 里 anchor 对应那条 item 的 stableId 作 scroll 锚。
        // Fallback：rows 为空则无锚可用（不应发生，entries 非空 walk 至少 1 行）。
        guard let phase1AnchorStableId: AnyHashable = {
            let idx = phase1Walk.anchorItemIndex
            if idx >= 0, idx < phase1Rows.count { return phase1Rows[idx].stableId }
            return phase1Rows.first?.stableId
        }() else {
            appLog(.warning, "TranscriptController",
                "runViewportFirstAroundAnchor: empty phase1Rows; falling back to bottom")
            runViewportFirstBottom(
                entries: entries, theme: transcriptTheme, width: width,
                expandedSnapshot: expandedSnapshot, engine: engine,
                generation: generation, t0: t0)
            return
        }
        self.merge(
            with: phase1Transition,
            scroll: .anchor(stableId: phase1AnchorStableId, topOffset: anchorTopOffset))
        self.logVisualSnapshot(
            tag: "phase1-merged",
            expectedAnchorStableId: phase1AnchorStableId,
            expectedTopOffset: anchorTopOffset)
        let tPhase1Done = CFAbsoluteTimeGetCurrent()
        let phase1Ms = Int((tPhase1Done - t0) * 1000)
        let openStart = self.openStartedAt
        let openCacheHitBase = self.openCacheHitBaseline
        let openCacheMissBase = self.openCacheMissBaseline
        let openEntryCount = entries.count
        let openPhase1Rows = phase1Rows.count
        let openBudgetTag = budget.tag
        let openWidth = Int(width)

        let phase1Items = phase1Walk.items
        let leftEntries = Array(entries.prefix(phase1Walk.startEntryIndex))
        let rightEntries = Array(entries.suffix(from: phase1Walk.endEntryIndex + 1))

        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tPrepStart = CFAbsoluteTimeGetCurrent()
            let leftPrepared = TranscriptRowBuilder.prepareAll(
                entries: leftEntries,
                theme: transcriptTheme,
                width: width,
                expandedUserBubbles: expandedSnapshot)
            let rightPrepared = TranscriptRowBuilder.prepareAll(
                entries: rightEntries,
                theme: transcriptTheme,
                width: width,
                expandedUserBubbles: expandedSnapshot)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            var combinedItems = leftPrepared + phase1Items + rightPrepared
            let (hlMs, codeBlockCount, tokensByStableId) =
                await Self.applyHighlightTokens(
                    to: &combinedItems,
                    theme: transcriptTheme,
                    width: width,
                    engine: engine)
            if Task.isCancelled { return }
            let tHlDone = CFAbsoluteTimeGetCurrent()

            let coloredLeft = Array(combinedItems.prefix(leftPrepared.count))
            let coloredRight = Array(combinedItems.suffix(rightPrepared.count))

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()

                self.backfillHighlightTokens(
                    tokensByStableId: tokensByStableId, width: width)
                self.logVisualSnapshot(
                    tag: "phase2-post-backfill",
                    expectedAnchorStableId: phase1AnchorStableId,
                    expectedTopOffset: anchorTopOffset)

                // Phase 2 把 leftEntries 前插 + rightEntries 尾插。rows 现有
                // Phase 1 那段。全量 newRows = left + phase1 + right，走 diff。
                let leftRows = coloredLeft.map {
                    self.row(from: $0, theme: transcriptTheme)
                }
                let rightRows = coloredRight.map {
                    self.row(from: $0, theme: transcriptTheme)
                }
                let newFullRows = leftRows + self.rows + rightRows
                let phase2Transition = TranscriptDiff.compute(
                    old: self.rows, new: newFullRows, animated: false)
                self.syncExpansionAndSize(phase2Transition.finalRows, width: width)

                // 继续用 anchor row 的 topOffset 钉住 —— left 前插会把 anchor
                // 往下挤，`.anchor` 会把 clipView 往下 scroll 同样多来抵消。
                self.merge(
                    with: phase2Transition,
                    scroll: .anchor(
                        stableId: phase1AnchorStableId,
                        topOffset: anchorTopOffset))
                self.logVisualSnapshot(
                    tag: "phase2-merged",
                    expectedAnchorStableId: phase1AnchorStableId,
                    expectedTopOffset: anchorTopOffset)

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
                    "setEntries initialPaint(anchored) "
                    + "TTFP=\(phase1Ms)ms full=\(totalMs)ms "
                    + "phase1=\(phase1Walk.endEntryIndex - phase1Walk.startEntryIndex + 1)(rows=\(phase1Rows.count)) "
                    + "phase2=\(leftEntries.count + rightEntries.count) "
                    + "(+\(phase2Transition.inserted.count) / ~\(phase2Transition.updated.count) / -\(phase2Transition.deleted.count) / reused=\(reusedCount)) "
                    + "prepare=\(prepMs) bg=\(bgMs)(hl=\(hlMs)ms code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) width=\(Int(width)) "
                    + "scroll=anchor budget=\(budget.tag)")

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
                        scrollTag: "anchor")
                    appLog(.info, "TranscriptController", OpenMetrics.format(snapshot))
                    self.openStartedAt = nil
                }
            }
        }
    }

    /// `.liveAppend` pipeline：caller 保证 `entries` 是当前 `rows` 对应 entry ids
    /// 的严格尾部扩展（`entries[..<oldSigCount]` == 上次 signature）。只 prepare +
    /// highlight 新增 entries、尾部 insert，scroll `.preserve`，不跑 TranscriptDiff。
    func runLiveAppend(
        entries: [MessageEntry],
        oldSigCount: Int,
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        expandedSnapshot: Set<AnyHashable>,
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        guard oldSigCount <= entries.count else {
            appLog(.warning, "TranscriptController",
                "liveAppend contract violation: old=\(oldSigCount) new=\(entries.count); skipping")
            return
        }
        let appendedEntries = Array(entries.suffix(from: oldSigCount))
        guard !appendedEntries.isEmpty else {
            appLog(.debug, "TranscriptController",
                "setEntries liveAppend appended=0 (no-op)")
            return
        }

        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
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

                self.syncExpansionAndSize(appendedRows, width: width)

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
                    "setEntries liveAppend appended=\(appendedEntries.count) rows=\(appendedRows.count) "
                    + "total=\(totalMs)ms hl=\(hlMs)ms(code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) width=\(Int(width))")
            }
        }
    }

    // MARK: - Expansion sync helper

    /// 把 controller 持有的「展开 id 集」反向同步给所有支持的 row，然后统一
    /// `makeSize`。merge 前的标准化步骤——ExpandableRow 的 row 读自身 stableId
    /// 是否在集合里决定状态；其他 row 此调用为空操作。
    fileprivate func syncExpansionAndSize(_ rows: [TranscriptRow], width: CGFloat) {
        for row in rows {
            (row as? ExpandableRow)?.applyExpansion(self.expandedUserBubbles)
            row.makeSize(width: width)
        }
    }

    // MARK: - Phase 1 budget

    fileprivate struct Phase1Budget {
        let height: CGFloat
        /// 保留 tag 给日志：调用点上游已经 `isLayoutReady()` 保证 clip > 0，
        /// 正常路径永远是 `"ok"`。出现其它值（目前只有 `"fallback-table"`）
        /// 代表 `isLayoutReady` 和 `phase1Budget` 之间出现了异常——属于
        /// 调用时序 bug 需排查，不是预期状态。
        let tag: String
    }

    fileprivate func phase1Budget() -> Phase1Budget {
        let clip = tableView?.enclosingScrollView?.contentView.bounds.height ?? 0
        if clip > 0 {
            return Phase1Budget(height: clip * 1.2, tag: "ok")
        }
        // isLayoutReady 把关后不应走到这里。兜一下防御，带异常 tag 报信号。
        let tableH = tableView?.bounds.height ?? 0
        appLog(.warning, "TranscriptController",
            "phase1Budget called with clip=0; isLayoutReady gate bypassed? tableH=\(tableH)")
        return Phase1Budget(height: max(tableH, 1) * 1.2, tag: "fallback-table")
    }

    /// 把 Phase 2 highlight 完成后 tokens 回写到已挂载的 rows。
    /// 主线程回灌：按 stableId 匹配到具体 row，调 `applyTokens` 把批量
    /// highlight 产出的 tokens 喂进去。今天 token 的唯一消费者是
    /// `AssistantMarkdownRow`——直接 cast，新增类型时再改成协议。
    fileprivate func backfillHighlightTokens(
        tokensByStableId: [AnyHashable: [AnyHashable: [SyntaxToken]]],
        width: CGFloat
    ) {
        var changed: IndexSet = []
        let visibleRange: NSRange
        if let tv = tableView, let clip = tv.enclosingScrollView?.contentView {
            visibleRange = tv.rows(in: clip.bounds)
        } else {
            visibleRange = NSRange(location: 0, length: 0)
        }
        var totalΔ: CGFloat = 0
        var visibleChanged = 0
        var visibleΔ: CGFloat = 0
        for (idx, row) in self.rows.enumerated() {
            guard let tokens = tokensByStableId[row.stableId],
                  let md = row as? AssistantMarkdownRow else { continue }
            let pre = row.cachedHeight
            md.applyTokens(tokens)
            row.makeSize(width: width)
            let delta = row.cachedHeight - pre
            totalΔ += delta
            if NSLocationInRange(idx, visibleRange) {
                visibleChanged += 1
                visibleΔ += delta
            }
            changed.insert(idx)
        }
        guard !changed.isEmpty else {
            appLog(.info, "TranscriptController",
                "[backfill] changed=0 (no mounted rows matched tokens)")
            return
        }
        appLog(.info, "TranscriptController",
            "[backfill] changed=\(changed.count) "
            + "visibleChanged=\(visibleChanged) "
            + "ΣΔ=\(String(format: "%.1f", totalΔ))pt "
            + "visibleΣΔ=\(String(format: "%.1f", visibleΔ))pt "
            + "visibleRange=\(visibleRange.location)..<\(visibleRange.location + visibleRange.length)")
        self.tableView?.noteHeightOfRows(withIndexesChanged: changed)
        for idx in changed {
            if let rv = self.tableView?.rowView(atRow: idx, makeIfNecessary: false)
                as? TranscriptRowView {
                rv.set(row: self.rows[idx])
            }
        }
    }

    // MARK: - Prepared → Row

    fileprivate func row(from item: TranscriptPreparedItem, theme: TranscriptTheme) -> TranscriptRow {
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

    /// 收集 `items` 中 assistant 的 code block + diff 的 unique 行内容
    /// → 一次 highlightBatch → 把 tokens 折回对应 prepared / layout → 在
    /// `items` 上 in-place 替换；同时回传 `tokensByStableId` 供主线程
    /// `backfillHighlightTokens` 喂给已挂载的 rows。
    ///
    /// tokensByStableId 的 inner key 是 `AnyHashable`：
    /// - Assistant: `Int`（segmentIndex）
    /// - Diff:      `String`（行内容）
    /// 两边共用同一条 `AssistantMarkdownRow.applyTokens` 通道（diff 消费者
    /// 之前存在过，现不在；接口仍保留 AnyHashable 以防后续再引入）。
    nonisolated fileprivate static func applyHighlightTokens(
        to items: inout [TranscriptPreparedItem],
        theme: TranscriptTheme,
        width: CGFloat,
        engine: SyntaxHighlightEngine?
    ) async -> (hlMs: Int, codeBlockCount: Int, tokensByStableId: [AnyHashable: [AnyHashable: [SyntaxToken]]]) {
        var requests: [(code: String, language: String?)] = []
        var routing: [(itemIndex: Int, innerKey: AnyHashable)] = []

        for (itemIdx, item) in items.enumerated() {
            switch item {
            case .assistant(let prepared, _):
                guard !prepared.hasHighlight else { continue }
                for (segIdx, seg) in prepared.parsedDocument.segments.enumerated() {
                    if case .codeBlock(let block) = seg {
                        requests.append((block.code, block.language))
                        routing.append((itemIdx, AnyHashable(segIdx)))
                    }
                }
            case .user, .placeholder:
                continue
            }
        }

        let totalCount = requests.count
        guard !requests.isEmpty, let engine else {
            return (0, totalCount, [:])
        }
        if Task.isCancelled { return (0, totalCount, [:]) }

        await engine.load()
        if Task.isCancelled { return (0, totalCount, [:]) }

        let t0 = CFAbsoluteTimeGetCurrent()
        let batch = await engine.highlightBatch(requests)
        let hlMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard batch.count == routing.count else {
            appLog(.warning, "TranscriptController",
                "highlight batch size mismatch: got \(batch.count) expected \(routing.count)")
            return (hlMs, totalCount, [:])
        }

        // Group tokens by itemIdx (inner key remains AnyHashable).
        var byItem: [Int: [AnyHashable: [SyntaxToken]]] = [:]
        for (i, route) in routing.enumerated() {
            byItem[route.itemIndex, default: [:]][route.innerKey] = batch[i]
        }

        // Fold back into each item; write to cache for re-entry reuse.
        var tokensByStableId: [AnyHashable: [AnyHashable: [SyntaxToken]]] = [:]
        for (itemIdx, innerTokens) in byItem {
            switch items[itemIdx] {
            case .assistant(let prepared, _):
                var segTokens: [Int: [SyntaxToken]] = [:]
                for (k, v) in innerTokens {
                    if let i = k.base as? Int { segTokens[i] = v }
                }
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
                tokensByStableId[prepared.stable] = innerTokens
                // Cache Prepared only — Layout is width-dependent and always
                // recomputed. This overwrite flips `hasHighlight` false→true
                // at the same key (contentHash excludes hasHighlight).
                TranscriptPrepareCache.shared.put(
                    newItem.cacheKey, newItem.preparedOnly)

            case .user, .placeholder:
                continue
            }
        }
        return (hlMs, totalCount, tokensByStableId)
    }
}

import AppKit

/// `setEntries` 按 `TranscriptUpdateReason` 分发的 4 条 pipeline + 共用助手。
extension TranscriptController {
    // MARK: - Pipelines

    func runFullDiffMerge(
        entries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable],
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
                stickyStates: stickyStates)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            let (hlMs, codeBlockCount) = await Self.applyHighlightTokens(
                to: &items, theme: transcriptTheme, width: width, engine: engine)
            if Task.isCancelled { return }
            let tHlDone = CFAbsoluteTimeGetCurrent()

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()

                let newRows = items.map { $0.makeRow(theme: transcriptTheme) }
                let transition = TranscriptDiff.compute(
                    old: self.rows, new: newRows, animated: false)
                self.merge(with: transition, scroll: scroll)
                self.logVisualSnapshot(
                    tag: "\(tag)-merged",
                    expectedAnchorStableId: scroll.anchorStableId,
                    expectedTopOffset: scroll.anchorTopOffset)

                let liveIds = Set(self.rows.map { $0.stableId })
                self.stickyStates = self.stickyStates.filter { liveIds.contains($0.key) }
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
            await self?.runPendingRowRefinements(width: width, engine: engine)
        }
    }

    func runViewportFirstBottom(
        entries: [MessageEntry],
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable],
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        let budget = phase1Budget()

        let phase1Walk = TranscriptRowBuilder.prepareBoundedTail(
            entries: entries,
            theme: transcriptTheme,
            width: width,
            stickyStates: stickyStates,
            minAccumulatedHeight: budget.height)
        let phase1StartIndex = phase1Walk.phase1StartIndex
        let phase1Rows = phase1Walk.items.map { $0.makeRow(theme: transcriptTheme) }

        let phase1Transition = TranscriptDiff.compute(
            old: rows, new: phase1Rows, animated: false)
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

        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tPrepStart = CFAbsoluteTimeGetCurrent()
            // entryCount 必须是全局 entries 的长度:GroupComponent 用
            // `entryIndex == entryCount - 1` 判 isActive,只传 prefix 长度
            // 会让 prefix 末尾 entry 被误判为全局最后一条。
            let prefixPreparedOnly = TranscriptRowBuilder.prepareAll(
                entries: prefixEntries,
                theme: transcriptTheme,
                width: width,
                stickyStates: stickyStates,
                entryCount: entries.count)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            var combinedItems = prefixPreparedOnly + phase1Items
            let (hlMs, codeBlockCount) =
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

                let scroll: TranscriptScrollIntent =
                    self.anchorToCurrentTop() ?? .preserve

                let prefixRows = coloredPrefix.map {
                    $0.makeRow(theme: transcriptTheme)
                }
                let newFullRows = prefixRows + self.rows
                let phase2Transition = TranscriptDiff.compute(
                    old: self.rows, new: newFullRows, animated: false)
                self.merge(with: phase2Transition, scroll: scroll)
                self.logVisualSnapshot(
                    tag: "bottom-phase2-merged",
                    expectedAnchorStableId: scroll.anchorStableId,
                    expectedTopOffset: scroll.anchorTopOffset)

                let liveIds = Set(self.rows.map { $0.stableId })
                self.stickyStates = self.stickyStates.filter { liveIds.contains($0.key) }
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
            await self?.runPendingRowRefinements(width: width, engine: engine)
        }
    }

    func runViewportFirstAroundAnchor(
        entries: [MessageEntry],
        anchorEntryIndex: Int,
        anchorTopOffset: CGFloat,
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable],
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        let budget = phase1Budget()

        let clipH = tableView?.enclosingScrollView?.contentView.bounds.height ?? 0
        let margin = max(0, budget.height - clipH)
        let aboveBudget = max(0, anchorTopOffset) + margin
        let belowBudget = max(0, clipH - anchorTopOffset) + margin

        let phase1Walk = TranscriptRowBuilder.prepareBoundedAround(
            entries: entries,
            anchorEntryIndex: anchorEntryIndex,
            theme: transcriptTheme,
            width: width,
            stickyStates: stickyStates,
            aboveMinHeight: aboveBudget,
            belowMinHeight: belowBudget)
        let phase1Rows = phase1Walk.items.map { $0.makeRow(theme: transcriptTheme) }

        let phase1Transition = TranscriptDiff.compute(
            old: rows, new: phase1Rows, animated: false)
        guard let phase1AnchorStableId: StableId = {
            let idx = phase1Walk.anchorItemIndex
            if idx >= 0, idx < phase1Rows.count { return phase1Rows[idx].stableId }
            return phase1Rows.first?.stableId
        }() else {
            appLog(.warning, "TranscriptController",
                "runViewportFirstAroundAnchor: empty phase1Rows; falling back to bottom")
            runViewportFirstBottom(
                entries: entries, theme: transcriptTheme, width: width,
                stickyStates: stickyStates, engine: engine,
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
            // entryCount 必须是全局 entries 的长度 —— 原因见 runViewportFirstBottom 注释。
            let leftPrepared = TranscriptRowBuilder.prepareAll(
                entries: leftEntries,
                theme: transcriptTheme,
                width: width,
                stickyStates: stickyStates,
                entryCount: entries.count)
            let rightPrepared = TranscriptRowBuilder.prepareAll(
                entries: rightEntries,
                theme: transcriptTheme,
                width: width,
                stickyStates: stickyStates,
                entryCount: entries.count)
            let tPrepDone = CFAbsoluteTimeGetCurrent()
            if Task.isCancelled { return }

            var combinedItems = leftPrepared + phase1Items + rightPrepared
            let (hlMs, codeBlockCount) =
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

                let leftRows = coloredLeft.map { $0.makeRow(theme: transcriptTheme) }
                let rightRows = coloredRight.map { $0.makeRow(theme: transcriptTheme) }
                let newFullRows = leftRows + self.rows + rightRows
                let phase2Transition = TranscriptDiff.compute(
                    old: self.rows, new: newFullRows, animated: false)

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
                self.stickyStates = self.stickyStates.filter { liveIds.contains($0.key) }
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
            await self?.runPendingRowRefinements(width: width, engine: engine)
        }
    }

    func runLiveAppend(
        entries: [MessageEntry],
        oldSigCount: Int,
        theme transcriptTheme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable],
        engine: SyntaxHighlightEngine?,
        generation: Int,
        t0: CFAbsoluteTime
    ) {
        guard oldSigCount <= entries.count else {
            appLog(.warning, "TranscriptController",
                "liveAppend contract violation: old=\(oldSigCount) new=\(entries.count); skipping")
            return
        }
        let appendedCount = entries.count - oldSigCount
        guard appendedCount > 0 else {
            appLog(.debug, "TranscriptController",
                "setEntries liveAppend appended=0 (no-op)")
            return
        }

        // Rebuild window = 前一条 oldLast + 新增 entries。
        // 前一条的 entryCount 从 oldSigCount → entries.count,isLastEntry 从 true
        // 翻 false → GroupComponent 的 contentHash 会变 → diff 判 updated
        // → reloadRowView → render 同步 sideCar.setActive(false)。
        // 其他不吃 isLastEntry 的 component(Assistant / User / Placeholder)
        // contentHash 不变 → carry-over 原 row,0 开销。
        let windowStartIdx = max(0, oldSigCount - 1)
        let windowEntries = Array(entries[windowStartIdx..<entries.count])
        let totalCount = entries.count

        activePreprocessTask = Task.detached(priority: .userInitiated) { [weak self] in
            // entryIndex 对齐原 entries 的全局下标 —— 通过 windowStartIdx 偏移。
            var items: [AnyPreparedItem] = []
            items.reserveCapacity(windowEntries.count)
            for (offset, entry) in windowEntries.enumerated() {
                let globalIdx = windowStartIdx + offset
                items.append(contentsOf: TranscriptComponentRegistry.itemsForEntry(
                    entry,
                    entryIndex: globalIdx,
                    entryCount: totalCount,
                    theme: transcriptTheme,
                    width: width,
                    stickyStates: stickyStates))
            }
            if Task.isCancelled { return }

            let (hlMs, codeBlockCount) = await Self.applyHighlightTokens(
                to: &items, theme: transcriptTheme, width: width, engine: engine)
            if Task.isCancelled { return }

            await MainActor.run {
                guard let self, self.setEntriesGeneration == generation else { return }
                let tMergeStart = CFAbsoluteTimeGetCurrent()

                // 找到 oldLast(entries[oldSigCount - 1])在 self.rows 里的起始下标。
                // oldSigCount == 0 时 splitIdx = 0(no oldLast)。
                let splitIdx: Int
                if oldSigCount > 0 {
                    let oldLastEntryId = entries[oldSigCount - 1].id
                    splitIdx = self.rows.firstIndex { $0.stableId.entryId == oldLastEntryId }
                        ?? self.rows.count
                } else {
                    splitIdx = 0
                }

                let prefixRows = Array(self.rows[0..<splitIdx])
                let windowRows = items.map { $0.makeRow(theme: transcriptTheme) }
                let newRows = prefixRows + windowRows

                let transition = TranscriptDiff.compute(
                    old: self.rows, new: newRows, animated: false)
                self.merge(with: transition, scroll: .preserve)

                let liveIds = Set(self.rows.map { $0.stableId })
                self.stickyStates = self.stickyStates.filter { liveIds.contains($0.key) }

                let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let mergeMs = Int((CFAbsoluteTimeGetCurrent() - tMergeStart) * 1000)
                appLog(.info, "TranscriptController",
                    "setEntries liveAppend appended=\(appendedCount) "
                    + "windowRows=\(windowRows.count) "
                    + "(+\(transition.inserted.count) / ~\(transition.updated.count) / -\(transition.deleted.count)) "
                    + "total=\(totalMs)ms hl=\(hlMs)ms(code=\(codeBlockCount)) "
                    + "merge=\(mergeMs) width=\(Int(width))")
            }
            await self?.runPendingRowRefinements(width: width, engine: engine)
        }
    }

    // MARK: - Phase 1 budget

    struct Phase1Budget {
        let height: CGFloat
        let tag: String
    }

    func phase1Budget() -> Phase1Budget {
        let clip = tableView?.enclosingScrollView?.contentView.bounds.height ?? 0
        if clip > 0 {
            return Phase1Budget(height: clip * 1.2, tag: "ok")
        }
        let tableH = tableView?.bounds.height ?? 0
        appLog(.warning, "TranscriptController",
            "phase1Budget called with clip=0; isLayoutReady gate bypassed? tableH=\(tableH)")
        return Phase1Budget(height: max(tableH, 1) * 1.2, tag: "fallback-table")
    }

    // MARK: - Refinement scheduler

    /// 主线程 run-pending refinement 调度 —— 给所有挂载 rows 收集 refinement,
    /// 并发执行,把每个 ContentPatch 折回 row 的 content,重跑 layout。
    func runPendingRowRefinements(width: CGFloat, engine: SyntaxHighlightEngine?) async {
        let mdTheme = self.theme ?? .default
        let transcriptTheme = TranscriptTheme(markdown: mdTheme)
        let context = RefinementContext(theme: transcriptTheme, syntaxEngine: engine)

        // 收集 (rowStableId, AnyRefinement) 对(每 row 多 refinement 都 flatten)。
        struct WorkItem: Sendable {
            let stableId: StableId
            let refinement: AnyRefinement
        }
        var works: [WorkItem] = []
        for row in self.rows {
            let cb = row.callbacks
            let refs = cb.refinements(row.content, context)
            for r in refs {
                works.append(WorkItem(stableId: row.stableId, refinement: r))
            }
        }
        guard !works.isEmpty else { return }

        struct Result: Sendable {
            let stableId: StableId
            let patch: AnyContentPatch
        }

        var results: [Result] = []
        await withTaskGroup(of: Result.self) { group in
            for w in works {
                group.addTask {
                    let patch = await w.refinement.run()
                    return Result(stableId: w.stableId, patch: patch)
                }
            }
            for await r in group { results.append(r) }
        }

        let visibleRange: NSRange
        if let tv = tableView, let clip = tv.enclosingScrollView?.contentView {
            visibleRange = tv.rows(in: clip.bounds)
        } else {
            visibleRange = NSRange(location: 0, length: 0)
        }

        let preHeights = self.rows.map { $0.cachedSize.height }
        // Apply patches.
        for r in results {
            guard let idx = self.rows.firstIndex(where: { $0.stableId == r.stableId }) else { continue }
            let cb = self.rows[idx].callbacks
            let newContent = r.patch.applyErased(self.rows[idx].content)
            self.rows[idx].content = newContent
            let new = cb.layoutFull(newContent, self.rows[idx].state, transcriptTheme, width)
            self.rows[idx].layout = new
            self.rows[idx].cachedSize = CGSize(width: width, height: new.cachedHeight)
        }

        var changed: IndexSet = []
        var totalΔ: CGFloat = 0
        var visibleChanged = 0
        var visibleΔ: CGFloat = 0
        for (idx, row) in self.rows.enumerated() {
            let delta = row.cachedSize.height - preHeights[idx]
            guard delta != 0 else { continue }
            totalΔ += delta
            if NSLocationInRange(idx, visibleRange) {
                visibleChanged += 1
                visibleΔ += delta
            }
            changed.insert(idx)
        }
        guard !changed.isEmpty else {
            appLog(.info, "TranscriptController",
                "[refine] changed=0 (no mounted rows affected)")
            return
        }
        appLog(.info, "TranscriptController",
            "[refine] changed=\(changed.count) "
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

    // MARK: - Highlight pipeline (off-main batch)

    /// 收集 items 的 highlight 请求 → 一次 engine.highlightBatch → 把 tokens 折回
    /// items(协议方法 `applyingTokens`)。
    nonisolated fileprivate static func applyHighlightTokens(
        to items: inout [AnyPreparedItem],
        theme: TranscriptTheme,
        width: CGFloat,
        engine: SyntaxHighlightEngine?
    ) async -> (hlMs: Int, codeBlockCount: Int) {
        var requests: [(code: String, language: String?)] = []
        var routing: [(itemIndex: Int, innerKey: AnyHashable)] = []

        for (itemIdx, item) in items.enumerated() {
            for req in item.highlightRequests() {
                requests.append((req.code, req.language))
                routing.append((itemIdx, req.innerKey))
            }
        }

        let totalCount = requests.count
        guard !requests.isEmpty, let engine else {
            return (0, totalCount)
        }
        if Task.isCancelled { return (0, totalCount) }

        await engine.load()
        if Task.isCancelled { return (0, totalCount) }

        let t0 = CFAbsoluteTimeGetCurrent()
        let batch = await engine.highlightBatch(requests)
        let hlMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard batch.count == routing.count else {
            appLog(.warning, "TranscriptController",
                "highlight batch size mismatch: got \(batch.count) expected \(routing.count)")
            return (hlMs, totalCount)
        }

        var byItem: [Int: [AnyHashable: [SyntaxToken]]] = [:]
        for (i, route) in routing.enumerated() {
            byItem[route.itemIndex, default: [:]][route.innerKey] = batch[i]
        }

        for (itemIdx, innerTokens) in byItem {
            let oldItem = items[itemIdx]
            let newItem = oldItem.applyingTokens(
                innerTokens, theme: theme, width: width)
            items[itemIdx] = newItem
        }
        return (hlMs, totalCount)
    }
}

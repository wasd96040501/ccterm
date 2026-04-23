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
    /// 首个 `.initialPaint` 的 Phase 2 merge 完成时读这个值算 TTFP，emit 后清零
    /// —— 一次性指标，不会重复打印。
    var openStartedAt: CFAbsoluteTime?

    /// session-open 的 cache delta baseline。`.initialPaint` 入口记录；Phase 2
    /// merge 出口做 delta 算 hit/miss。
    private var openCacheHitBaseline: Int = 0
    private var openCacheMissBaseline: Int = 0

    /// 用户手动展开过的 UserBubble 的 stableId 集合。
    ///
    /// Sticky：toggle 过就进 set，再 toggle 出 set。resize 换宽度不动这里。
    /// Row 上的 `isExpanded` 只是 render-time cache，source of truth 是这个 set
    /// ——controller 在每次 layout pass 之前把 row.isExpanded sync 回来。
    private var expandedUserBubbles: Set<AnyHashable> = []

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
        if case .idle = reason { return }

        // Layout not ready yet (刚 makeNSView + updateNSView 先于第一次 layout)。
        // 不跑 pipeline —— 缓存到 pending，由 `tableWidthChanged` 在真实 frame
        // 到手后 flush。每次 stash 覆盖旧 pending，天然采用最新 snapshot。
        if !isLayoutReady() {
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
    private func anchorToCurrentTop() -> TranscriptScrollIntent? {
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

    // MARK: - Pipelines

    /// 全量 diff merge。后台 prepare + highlight，回主线程一次性 `TranscriptDiff`
    /// 合并并应用给定 scroll intent。`.prependHistory` / `.update` 共用。
    private func runFullDiffMerge(
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
        for row in phase1Transition.finalRows {
            if let u = row as? UserBubbleRow {
                u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
            }
            row.makeSize(width: width)
        }
        self.merge(with: phase1Transition, scroll: .bottom)
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
    private func runViewportFirstAroundAnchor(
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
        for row in phase1Transition.finalRows {
            if let u = row as? UserBubbleRow {
                u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
            }
            row.makeSize(width: width)
        }
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
                for row in phase2Transition.finalRows {
                    if let u = row as? UserBubbleRow {
                        u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
                    }
                    row.makeSize(width: width)
                }

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
    private func runLiveAppend(
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

                for row in appendedRows {
                    if let u = row as? UserBubbleRow {
                        u.isExpanded = self.expandedUserBubbles.contains(u.stableId)
                    }
                    row.makeSize(width: width)
                }

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

    // MARK: - Phase 1 budget

    private struct Phase1Budget {
        let height: CGFloat
        /// 保留 tag 给日志：调用点上游已经 `isLayoutReady()` 保证 clip > 0，
        /// 正常路径永远是 `"ok"`。出现其它值（目前只有 `"fallback-table"`）
        /// 代表 `isLayoutReady` 和 `phase1Budget` 之间出现了异常——属于
        /// 调用时序 bug 需排查，不是预期状态。
        let tag: String
    }

    private func phase1Budget() -> Phase1Budget {
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
    /// 主线程回灌：把批量 highlight 产出的 tokens 喂给已挂载的 rows。
    /// Row-type-agnostic：走 `FragmentRow.applyTokens` 协议，按 stableId
    /// 找到对应 row 后 dispatch——assistant 的 `[Int: tokens]` 和 diff 的
    /// `[String: tokens]` 共用同一个 AnyHashable-keyed 通道。
    private func backfillHighlightTokens(
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
                  let fr = row as? FragmentRow else { continue }
            let pre = row.cachedHeight
            fr.applyTokens(tokens)
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
        case .diff(let prepared, let layout):
            let r = DiffRow(prepared: prepared, theme: theme)
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
    /// 两边共用同一条 FragmentRow.applyTokens 通道。
    nonisolated private static func applyHighlightTokens(
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
            case .diff(let prepared, _):
                guard !prepared.hasHighlight else { continue }
                var seen: Set<String> = []
                for hunk in prepared.hunks {
                    for line in hunk.lines {
                        let content = line.content
                        if content.isEmpty || seen.contains(content) { continue }
                        seen.insert(content)
                        requests.append((content, prepared.language))
                        routing.append((itemIdx, AnyHashable(content)))
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

            case .diff(let prepared, _):
                var lineHighlights = prepared.lineHighlights
                for (k, v) in innerTokens {
                    if let s = k.base as? String { lineHighlights[s] = v }
                }
                let newPrepared = DiffPrepared(
                    filePath: prepared.filePath,
                    hunks: prepared.hunks,
                    language: prepared.language,
                    suppressInsertionStyle: prepared.suppressInsertionStyle,
                    stable: prepared.stable,
                    contentHash: prepared.contentHash,
                    lineHighlights: lineHighlights,
                    hasHighlight: true)
                let newLayout = TranscriptPrepare.layoutDiff(
                    prepared: newPrepared, theme: theme, width: width)
                let newItem: TranscriptPreparedItem = .diff(newPrepared, newLayout)
                items[itemIdx] = newItem
                tokensByStableId[prepared.stable] = innerTokens
                TranscriptPrepareCache.shared.put(
                    newItem.cacheKey, newItem.preparedOnly)

            case .user, .placeholder:
                continue
            }
        }
        return (hlMs, totalCount, tokensByStableId)
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
                appLog(.warning, "TranscriptController",
                    "[scroll] .anchor stableId not found in rows (\(rows.count) rows)")
                return
            }
            let newRect = tableView.rect(ofRow: idx)
            let newY = newRect.minY - topOffset
            let maxY = max(0, tableView.bounds.height - clip.bounds.height)
            let clamped = max(0, min(newY, maxY))
            let clampTag: String
            if newY < 0 { clampTag = "clamp→0(over \(String(format: "%.1f", -newY))pt)" }
            else if newY > maxY { clampTag = "clamp→maxY(over \(String(format: "%.1f", newY - maxY))pt)" }
            else { clampTag = "ok" }
            appLog(.info, "TranscriptController",
                "[scroll] .anchor idx=\(idx) rowY=\(Int(newRect.minY)) "
                + "topOffset=\(String(format: "%.1f", topOffset)) "
                + "newY=\(String(format: "%.1f", newY)) maxY=\(Int(maxY)) "
                + "clipY=\(Int(clip.bounds.minY))→\(String(format: "%.1f", clamped)) "
                + "tableH=\(Int(tableView.bounds.height)) "
                + "clipH=\(Int(clip.bounds.height)) [\(clampTag)]")
            guard abs(clamped - clip.bounds.minY) > 0.5 else { return }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clamped))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Diagnostic snapshot of the current scroll state vs. what an anchor
    /// target implies. Written at the four critical points of
    /// `runViewportFirstAroundAnchor` so we can tell **which step introduces
    /// drift**:
    /// - `phase1-merged`: 第一帧是否已对齐 `(stableId, topOffset)`
    /// - `phase2-post-backfill`: highlight 回灌 + noteHeightOfRows 是否扰动了
    ///   clipY / anchor rowY 的相对关系
    /// - `phase2-merged`: Phase 2 前插 + re-anchor 后是否仍对齐
    /// Δ = actualTopOffset - expectedTopOffset; >1pt 代表视觉已错位。
    private func logVisualSnapshot(
        tag: String,
        expectedAnchorStableId: AnyHashable?,
        expectedTopOffset: CGFloat?
    ) {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else {
            appLog(.info, "TranscriptController",
                "[snap] \(tag): no tableView/clipView")
            return
        }
        let tableH = tableView.bounds.height
        let clipH = clip.bounds.height
        let clipY = clip.bounds.minY
        let maxY = max(0, tableH - clipH)

        var anchorInfo = "anchor=none"
        if let stableId = expectedAnchorStableId,
           let idx = rows.firstIndex(where: { $0.stableId == stableId })
        {
            let rect = tableView.rect(ofRow: idx)
            let actual = rect.minY - clipY
            let expected = expectedTopOffset ?? 0
            let delta = actual - expected
            anchorInfo = "anchorIdx=\(idx) rowY=\(Int(rect.minY)) "
                + "actualTopOffset=\(String(format: "%.1f", actual)) "
                + "expected=\(String(format: "%.1f", expected)) "
                + "Δ=\(String(format: "%.2f", delta))pt"
        } else if expectedAnchorStableId != nil {
            anchorInfo = "anchor=stableId-not-in-rows"
        }

        appLog(.info, "TranscriptController",
            "[snap] \(tag) clipY=\(Int(clipY)) maxY=\(Int(maxY)) "
            + "tableH=\(Int(tableH)) clipH=\(Int(clipH)) "
            + "rows=\(rows.count) \(anchorInfo)")
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

    // MARK: - Row-local point conversion

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

    func rowLocalContext(at documentPoint: CGPoint) -> RowLocalContext? {
        guard let tableView else { return nil }
        return rowLocalContext(forRow: tableView.row(at: documentPoint))
    }

    func rowLocalContext(forRow rowIndex: Int) -> RowLocalContext? {
        guard let tableView, rowIndex >= 0, rowIndex < rows.count else { return nil }
        let rowRect = tableView.rect(ofRow: rowIndex)
        let inset = contentInset(forRow: rowIndex, rowRect: rowRect)
        return RowLocalContext(rowIndex: rowIndex, rowRect: rowRect, inset: inset)
    }

    // MARK: - Link hit-test

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

    func codeBlockHit(atDocumentPoint documentPoint: CGPoint) -> Bool {
        return resolveCodeBlockHit(atDocumentPoint: documentPoint) != nil
    }

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
        rowView.set(row: rows[index])
    }

    // MARK: - User bubble collapse toggle

    func isOverUserBubbleChevron(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard let ctx = rowLocalContext(at: documentPoint) else { return false }
        guard let row = rows[ctx.rowIndex] as? UserBubbleRow else { return false }
        let pointInRow = ctx.toRowLocal(documentPoint)
        return row.chevronHitRectInRow()?.contains(pointInRow) == true
    }

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

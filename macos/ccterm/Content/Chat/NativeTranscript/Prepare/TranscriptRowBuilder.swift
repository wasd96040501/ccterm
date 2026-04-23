import AgentSDK
import Foundation

/// 把一串 `MessageEntry` 映射到 `[TranscriptRow]`——纯函数，同输入同输出。
///
/// 规则：
/// - `.single(.user)` 有 plainText → `UserBubbleRow`
/// - `.single(.user)` 其他（比如 tool_result）→ 跳过，不渲染
/// - `.single(.assistant)` 仅 text → `AssistantMarkdownRow`
/// - `.single(.assistant)` 仅 tool_use → 按顺序 `PlaceholderRow("[Tool: N]")`
/// - `.single(.assistant)` text + tool_use 混合 → 按 block 顺序拆成 markdown + placeholders
/// - `.single(.assistant)` 只含 thinking / unknown → 跳过
/// - `.group` → 单条 `PlaceholderRow("[Tools × N]")`
enum TranscriptRowBuilder {

    @MainActor
    static func build(
        entries: [MessageEntry],
        theme: MarkdownTheme,
        expandedUserBubbles: Set<AnyHashable> = []
    ) -> [TranscriptRow] {
        let transcriptTheme = TranscriptTheme(markdown: theme)
        var out: [TranscriptRow] = []

        for entry in entries {
            switch entry {
            case .single(let single):
                append(
                    from: single,
                    theme: transcriptTheme,
                    expandedUserBubbles: expandedUserBubbles,
                    into: &out)
            case .group(let group):
                let label = "[Tools × \(group.items.count)]"
                out.append(PlaceholderRow(
                    label: label,
                    theme: transcriptTheme,
                    stable: group.id))
            }
        }
        return out
    }

    /// Nonisolated counterpart to ``build(entries:theme:expandedUserBubbles:)``.
    /// Runs parse + prebuild + width-aware layout on whatever thread the
    /// caller picks (typically `Task.detached`). Output is a list of Sendable
    /// prepared items; the main thread wraps them into `TranscriptRow`
    /// instances via `TranscriptController.row(from:theme:)`.
    ///
    /// Does **not** perform syntax highlighting — callers schedule
    /// highlighting separately (see `TranscriptController.applyHighlightTokens`)
    /// and fold tokens back in before rows are constructed on main.
    nonisolated static func prepareAll(
        entries: [MessageEntry],
        theme: TranscriptTheme,
        width: CGFloat,
        expandedUserBubbles: Set<AnyHashable> = []
    ) -> [TranscriptPreparedItem] {
        var out: [TranscriptPreparedItem] = []
        out.reserveCapacity(entries.count)

        for entry in entries {
            appendPrepared(
                entry: entry, theme: theme, width: width,
                expandedUserBubbles: expandedUserBubbles, into: &out)
        }
        return out
    }

    /// Result of a height-bounded prepare walk.
    struct BoundedPrepareResult {
        let items: [TranscriptPreparedItem]
        /// Number of source `entries` consumed. Phase 2 continues from
        /// `entries[consumedEntryCount...]`.
        let consumedEntryCount: Int
    }

    /// Viewport-first walk. Consumes entries in order, accumulating prepared
    /// items' cachedHeight; stops as soon as `minAccumulatedHeight` is
    /// reached (typically the viewport height + a safety margin).
    ///
    /// A single entry can map to multiple items (assistant with tool_use
    /// blocks); the function always consumes a full entry before checking
    /// the height bound.
    nonisolated static func prepareBounded(
        entries: [MessageEntry],
        theme: TranscriptTheme,
        width: CGFloat,
        expandedUserBubbles: Set<AnyHashable>,
        minAccumulatedHeight: CGFloat
    ) -> BoundedPrepareResult {
        var items: [TranscriptPreparedItem] = []
        var accumulated: CGFloat = 0

        for (idx, entry) in entries.enumerated() {
            let beforeCount = items.count
            appendPrepared(
                entry: entry, theme: theme, width: width,
                expandedUserBubbles: expandedUserBubbles, into: &items)
            for i in beforeCount..<items.count {
                accumulated += heightOf(items[i])
            }
            if accumulated >= minAccumulatedHeight {
                return BoundedPrepareResult(
                    items: items, consumedEntryCount: idx + 1)
            }
        }
        return BoundedPrepareResult(
            items: items, consumedEntryCount: entries.count)
    }

    /// Result of a tail-bounded prepare walk.
    struct TailBoundedPrepareResult {
        /// Prepared items in **forward** order (oldest→newest) — ready to feed
        /// diff / row factories without reversal.
        let items: [TranscriptPreparedItem]
        /// Index into `entries` where this tail starts. Phase 2 prepends
        /// `entries[..<phase1StartIndex]`.
        let phase1StartIndex: Int
    }

    /// Telegram `.down` 语义下的 Phase 1 walk：从末尾往前累积 entries' cached
    /// height，直到 `>= minAccumulatedHeight` 为止。挂载的永远是「最新」那段。
    ///
    /// 输出 items 是 **forward** 顺序（内部倒序走完再翻转），消费方可以直接当
    /// `entries[phase1StartIndex...]` 对应的 Sendable 版 items 用。
    ///
    /// - Note: 一个 entry 可能展开成多条 item（assistant 混 tool_use）。walk
    ///   总是以 entry 为粒度（产完才检查累加），不会把同一 entry 的 items 拆开。
    nonisolated static func prepareBoundedTail(
        entries: [MessageEntry],
        theme: TranscriptTheme,
        width: CGFloat,
        expandedUserBubbles: Set<AnyHashable>,
        minAccumulatedHeight: CGFloat
    ) -> TailBoundedPrepareResult {
        // reverse 顺序累积到 items 里，最后翻转 + 算 startIndex。
        var reversedGroups: [[TranscriptPreparedItem]] = []
        var accumulated: CGFloat = 0
        var phase1StartIndex = entries.count

        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            var group: [TranscriptPreparedItem] = []
            appendPrepared(
                entry: entries[i], theme: theme, width: width,
                expandedUserBubbles: expandedUserBubbles, into: &group)
            for item in group { accumulated += heightOf(item) }
            reversedGroups.append(group)
            phase1StartIndex = i

            if accumulated >= minAccumulatedHeight { break }
        }

        // reversedGroups 是 [最新 entry 组, ..., 最老 entry 组]，
        // 每组内部仍是 forward 顺序（appendPrepared 按顺序 push）。
        // 翻转组顺序后 flatten 即得全局 forward 顺序。
        var forward: [TranscriptPreparedItem] = []
        forward.reserveCapacity(reversedGroups.reduce(0) { $0 + $1.count })
        for group in reversedGroups.reversed() {
            forward.append(contentsOf: group)
        }

        return TailBoundedPrepareResult(
            items: forward,
            phase1StartIndex: phase1StartIndex)
    }

    /// Anchor-centric viewport walk 的结果。
    ///
    /// `items` 保持 **forward** 顺序（entries 原序），其中 `anchorItemIndex`
    /// 指向 anchor entry 映射到 items 的**第一个** item（有的 entry 会展开成
    /// 多条 item，取第一条作为锚挂点）。
    struct AroundBoundedPrepareResult {
        let items: [TranscriptPreparedItem]
        /// `items` 里 anchor entry 的起始下标（不是 `entries` 的下标）。
        let anchorItemIndex: Int
        /// Phase 1 起止在 `entries` 的左右边界（闭区间 `[startIndex, endIndex]`）。
        /// Phase 2 需要补 `entries[..<startIndex]` 和 `entries[endIndex+1...]`。
        let startEntryIndex: Int
        let endEntryIndex: Int
    }

    /// Telegram `.top(id:)` + Phase 1 `.center` 展开的 ccterm 版本：以
    /// `entries[anchorEntryIndex]` 为中心，向**上下两侧**分别累加 entries 的
    /// item.cachedHeight，直到**双侧都**满足各自 budget 或两侧都耗尽。
    ///
    /// 双侧 budget 由 caller 依据 scroll anchor 的 `topOffset` 计算：要把 anchor
    /// 行放到 viewport 的 `topOffset` 位置，clip.minY 必须能到达 `Y_a - topOffset`。
    /// 可达性由 `tableH` 决定——Phase 1 的 tableH = aboveAccum + anchorH + belowAccum，
    /// 必须让:
    /// - `aboveAccum ≥ max(0, topOffset)` —— anchor 上方在 viewport 可见的部分
    /// - `belowAccum ≥ max(0, clipH - topOffset)` —— anchor 起至 viewport 底的部分
    ///   （含 anchor 自身高度，walker 把 anchor 计入 `belowAccum`）
    ///
    /// 否则 `applyScrollIntent .anchor` 会 clamp，Phase 1 渲染出错位帧；等 Phase 2
    /// 把 prefix/suffix 补齐才能跳到正确位置。这一个"先错后对"的视觉跳正是
    /// 用户感知到的"切 sidebar 时第一帧不对"。
    ///
    /// 规则：
    /// - anchor entry 一定入 Phase 1（算进 `belowAccum` 供 budget 判定）。
    /// - 左右两侧各自独立判定是否达标；一侧达标后只继续走另一侧。
    /// - 某一侧耗尽不阻塞另一侧继续走。
    /// - 输出 items 是 **forward** 顺序，`anchorItemIndex` 指向 anchor 的起始 item。
    ///
    /// 越界保护：`anchorEntryIndex` clamp 到 `[0, entries.count-1]`；entries 空
    /// → 空 result。
    nonisolated static func prepareBoundedAround(
        entries: [MessageEntry],
        anchorEntryIndex: Int,
        theme: TranscriptTheme,
        width: CGFloat,
        expandedUserBubbles: Set<AnyHashable>,
        aboveMinHeight: CGFloat,
        belowMinHeight: CGFloat
    ) -> AroundBoundedPrepareResult {
        guard !entries.isEmpty else {
            return AroundBoundedPrepareResult(
                items: [], anchorItemIndex: 0,
                startEntryIndex: 0, endEntryIndex: -1)
        }
        let anchor = max(0, min(anchorEntryIndex, entries.count - 1))

        // Prep anchor entry first —— anchor 自身高度计入 belowAccum（anchor 的
        // 可见部分位于 viewport 的 [topOffset, topOffset+anchorH] 区间，属于
        // "anchor 起至 viewport 底"的需求）。
        var anchorGroup: [TranscriptPreparedItem] = []
        appendPrepared(
            entry: entries[anchor], theme: theme, width: width,
            expandedUserBubbles: expandedUserBubbles, into: &anchorGroup)
        var belowAccumulated: CGFloat = anchorGroup.reduce(0) { $0 + heightOf($1) }
        var aboveAccumulated: CGFloat = 0

        var leftGroups: [[TranscriptPreparedItem]] = []   // 越上层顺序越后入，出时要 reverse
        var rightGroups: [[TranscriptPreparedItem]] = []  // 顺序与 entries 一致
        var leftIdx = anchor - 1
        var rightIdx = anchor + 1
        var startIdx = anchor
        var endIdx = anchor

        // 两侧独立判定：每轮分别 check 是否还需要扩。某一侧达标或耗尽就不再走。
        while (aboveAccumulated < aboveMinHeight && leftIdx >= 0)
            || (belowAccumulated < belowMinHeight && rightIdx < entries.count) {
            if aboveAccumulated < aboveMinHeight, leftIdx >= 0 {
                var group: [TranscriptPreparedItem] = []
                appendPrepared(
                    entry: entries[leftIdx], theme: theme, width: width,
                    expandedUserBubbles: expandedUserBubbles, into: &group)
                for item in group { aboveAccumulated += heightOf(item) }
                leftGroups.append(group)
                startIdx = leftIdx
                leftIdx -= 1
            }
            if belowAccumulated < belowMinHeight, rightIdx < entries.count {
                var group: [TranscriptPreparedItem] = []
                appendPrepared(
                    entry: entries[rightIdx], theme: theme, width: width,
                    expandedUserBubbles: expandedUserBubbles, into: &group)
                for item in group { belowAccumulated += heightOf(item) }
                rightGroups.append(group)
                endIdx = rightIdx
                rightIdx += 1
            }
        }

        // 拼接：leftGroups 反转后 + anchorGroup + rightGroups。
        var forward: [TranscriptPreparedItem] = []
        forward.reserveCapacity(
            anchorGroup.count
            + leftGroups.reduce(0) { $0 + $1.count }
            + rightGroups.reduce(0) { $0 + $1.count })
        for group in leftGroups.reversed() { forward.append(contentsOf: group) }
        let anchorItemIdx = forward.count
        forward.append(contentsOf: anchorGroup)
        for group in rightGroups { forward.append(contentsOf: group) }

        return AroundBoundedPrepareResult(
            items: forward,
            anchorItemIndex: anchorItemIdx,
            startEntryIndex: startIdx,
            endEntryIndex: endIdx)
    }

    nonisolated private static func appendPrepared(
        entry: MessageEntry,
        theme: TranscriptTheme,
        width: CGFloat,
        expandedUserBubbles: Set<AnyHashable>,
        into out: inout [TranscriptPreparedItem]
    ) {
        switch entry {
        case .single(let single):
            prepareAppend(
                from: single,
                theme: theme,
                expandedUserBubbles: expandedUserBubbles,
                width: width,
                into: &out)
        case .group(let group):
            let label = "[Tools × \(group.items.count)]"
            out.append(cachedOrBuildPlaceholder(
                label: label, theme: theme, stable: group.id))
        }
    }

    nonisolated private static func heightOf(_ item: TranscriptPreparedItem) -> CGFloat {
        switch item {
        case .assistant(_, let layout): return layout.cachedHeight
        case .user(_, let layout, _): return layout.cachedHeight
        case .placeholder(_, let layout): return layout.cachedHeight
        case .diff(_, let layout): return layout.cachedHeight
        }
    }

    // MARK: - prepareAppend (nonisolated, mirrors `append(from:…)`)

    nonisolated private static func prepareAppend(
        from single: SingleEntry,
        theme: TranscriptTheme,
        expandedUserBubbles: Set<AnyHashable>,
        width: CGFloat,
        into out: inout [TranscriptPreparedItem]
    ) {
        switch single.payload {
        case .localUser(let input):
            if let text = input.text, !text.isEmpty {
                let isExpanded = expandedUserBubbles.contains(AnyHashable(single.id))
                let item = cachedOrBuildUser(
                    text: text, theme: theme, width: width,
                    isExpanded: isExpanded, stable: single.id)
                out.append(item)
            }
            return

        case .remote(let message):
            switch message {
            case .user(let u):
                if let text = userPlainText(u), !text.isEmpty {
                    let isExpanded = expandedUserBubbles.contains(AnyHashable(single.id))
                    let item = cachedOrBuildUser(
                        text: text, theme: theme, width: width,
                        isExpanded: isExpanded, stable: single.id)
                    out.append(item)
                }
            case .assistant(let a):
                prepareAppendAssistant(
                    blocks: a.message?.content ?? [],
                    entryId: single.id,
                    theme: theme,
                    width: width,
                    into: &out)
            default:
                break
            }
        }
    }

    // MARK: - Cache-aware builders

    /// Compute the content hash for a user bubble the same way
    /// `TranscriptPrepare.user` does — **without** parsing — so we can look up
    /// the shared cache before doing any layout work.
    nonisolated private static func userContentHash(
        text: String, theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(text)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    /// Compute the content hash for an assistant markdown segment.
    nonisolated private static func assistantContentHash(
        source: String, theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(source)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    /// Compute the content hash for a placeholder label.
    nonisolated private static func placeholderContentHash(
        label: String, theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(label)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    /// 两步：cache lookup Prepared（parse + prebuild 结果，width 无关）→
    /// **无条件** 按当前精确 width 跑 `layoutUser`。这样 `heightOf(item)`
    /// 永远等于后续 `row.makeSize(width: width).cachedHeight`，不存在 drift。
    nonisolated private static func cachedOrBuildUser(
        text: String,
        theme: TranscriptTheme,
        width: CGFloat,
        isExpanded: Bool,
        stable: AnyHashable
    ) -> TranscriptPreparedItem {
        let contentHash = userContentHash(text: text, theme: theme)
        let key = TranscriptPrepareCache.Key(
            contentHash: contentHash, variant: .user)
        let prepared: UserPrepared
        if case .user(let p)? = TranscriptPrepareCache.shared.get(key)?
            .withStableId(stable)
        {
            prepared = p
        } else {
            prepared = TranscriptPrepare.user(text: text, theme: theme, stable: stable)
            TranscriptPrepareCache.shared.put(key, .user(prepared))
        }
        let layout = TranscriptPrepare.layoutUser(
            text: prepared.text, theme: theme,
            width: width, isExpanded: isExpanded)
        return .user(prepared, layout, isExpanded: isExpanded)
    }

    nonisolated private static func cachedOrBuildAssistant(
        source: String,
        theme: TranscriptTheme,
        width: CGFloat,
        stable: AnyHashable
    ) -> TranscriptPreparedItem {
        let contentHash = assistantContentHash(source: source, theme: theme)
        let key = TranscriptPrepareCache.Key(
            contentHash: contentHash, variant: .assistant)
        let prepared: AssistantPrepared
        if case .assistant(let p)? = TranscriptPrepareCache.shared.get(key)?
            .withStableId(stable)
        {
            prepared = p
        } else {
            prepared = TranscriptPrepare.assistant(
                source: source, theme: theme, stable: stable)
            // Plain prepared cached here; the highlight pass overwrites with
            // a token-enriched prepared once available (same key, contentHash
            // doesn't include hasHighlight).
            TranscriptPrepareCache.shared.put(key, .assistant(prepared))
        }
        let layout = TranscriptPrepare.layoutAssistant(
            prebuilt: prepared.prebuilt, theme: theme, width: width)
        return .assistant(prepared, layout)
    }

    nonisolated private static func cachedOrBuildPlaceholder(
        label: String,
        theme: TranscriptTheme,
        stable: AnyHashable
    ) -> TranscriptPreparedItem {
        let contentHash = placeholderContentHash(label: label, theme: theme)
        let key = TranscriptPrepareCache.Key(
            contentHash: contentHash, variant: .placeholder)
        let prepared: PlaceholderPrepared
        if case .placeholder(let p)? = TranscriptPrepareCache.shared.get(key)?
            .withStableId(stable)
        {
            prepared = p
        } else {
            prepared = TranscriptPrepare.placeholder(
                label: label, theme: theme, stable: stable)
            TranscriptPrepareCache.shared.put(key, .placeholder(prepared))
        }
        let layout = TranscriptPrepare.layoutPlaceholder(
            label: prepared.label, theme: theme)
        return .placeholder(prepared, layout)
    }

    nonisolated private static func cachedOrBuildDiff(
        filePath: String,
        oldString: String,
        newString: String,
        suppressInsertionStyle: Bool,
        theme: TranscriptTheme,
        width: CGFloat,
        stable: AnyHashable
    ) -> TranscriptPreparedItem {
        var hasher = Hasher()
        hasher.combine(filePath)
        hasher.combine(oldString)
        hasher.combine(newString)
        hasher.combine(suppressInsertionStyle)
        hasher.combine(theme.markdown.fingerprint)
        let contentHash = hasher.finalize()
        let key = TranscriptPrepareCache.Key(
            contentHash: contentHash, variant: .diff)
        let prepared: DiffPrepared
        if case .diff(let p)? = TranscriptPrepareCache.shared.get(key)?
            .withStableId(stable)
        {
            prepared = p
        } else {
            prepared = TranscriptPrepare.diff(
                filePath: filePath,
                oldString: oldString,
                newString: newString,
                suppressInsertionStyle: suppressInsertionStyle,
                theme: theme,
                stable: stable)
            TranscriptPrepareCache.shared.put(key, .diff(prepared))
        }
        let layout = TranscriptPrepare.layoutDiff(
            prepared: prepared, theme: theme, width: width)
        return .diff(prepared, layout)
    }

    /// Edit 的 input 是否够构造 diff：至少要有 `filePath` + 非空 old 或 new。
    nonisolated private static func editDiffArgs(
        _ edit: ToolUseEdit
    ) -> (filePath: String, oldString: String, newString: String)? {
        guard let input = edit.input,
              let filePath = input.filePath, !filePath.isEmpty else { return nil }
        let oldS = input.oldString ?? ""
        let newS = input.newString ?? ""
        guard !(oldS.isEmpty && newS.isEmpty) else { return nil }
        return (filePath, oldS, newS)
    }

    /// Write 的 input 是否够构造 diff：至少要有 `filePath` + 非空 `content`。
    nonisolated private static func writeDiffArgs(
        _ write: ToolUseWrite
    ) -> (filePath: String, content: String)? {
        guard let input = write.input,
              let filePath = input.filePath, !filePath.isEmpty,
              let content = input.content, !content.isEmpty else { return nil }
        return (filePath, content)
    }

    nonisolated private static func prepareAppendAssistant(
        blocks: [Message2AssistantMessageContent],
        entryId: UUID,
        theme: TranscriptTheme,
        width: CGFloat,
        into out: inout [TranscriptPreparedItem]
    ) {
        var textBuffer: [String] = []
        var textStartIndex = 0

        func flushText(endIndex: Int) {
            guard !textBuffer.isEmpty else { return }
            let source = textBuffer.joined(separator: "\n\n")
            let stableId: AnyHashable = "\(entryId.uuidString)-md-\(textStartIndex)" as String
            textBuffer.removeAll()
            out.append(cachedOrBuildAssistant(
                source: source, theme: theme, width: width, stable: stableId))
            textStartIndex = endIndex
        }

        for (idx, block) in blocks.enumerated() {
            switch block {
            case .text(let t):
                if let s = t.text, !s.isEmpty {
                    if textBuffer.isEmpty { textStartIndex = idx }
                    textBuffer.append(s)
                }
            case .toolUse(let u):
                flushText(endIndex: idx)
                let stableId: AnyHashable = "\(entryId.uuidString)-tool-\(idx)" as String
                if let item = toolUseDiffItem(
                    u, theme: theme, width: width, stable: stableId)
                {
                    out.append(item)
                } else {
                    out.append(cachedOrBuildPlaceholder(
                        label: "[Tool: \(u.caseName)]", theme: theme, stable: stableId))
                }
            case .thinking, .unknown:
                continue
            }
        }
        flushText(endIndex: blocks.count)
    }

    /// Edit / Write 路由：有完整 input 时返回 `.diff` prepared；否则 nil，
    /// caller 退回 placeholder（流式态下 input 尚未到齐，stableId 不变
    /// contentHash 变 → 下轮 diff 自动替换）。
    nonisolated private static func toolUseDiffItem(
        _ u: ToolUse,
        theme: TranscriptTheme,
        width: CGFloat,
        stable: AnyHashable
    ) -> TranscriptPreparedItem? {
        switch u {
        case .Edit(let edit):
            guard let args = editDiffArgs(edit) else { return nil }
            return cachedOrBuildDiff(
                filePath: args.filePath,
                oldString: args.oldString,
                newString: args.newString,
                suppressInsertionStyle: false,
                theme: theme, width: width, stable: stable)
        case .Write(let write):
            guard let args = writeDiffArgs(write) else { return nil }
            return cachedOrBuildDiff(
                filePath: args.filePath,
                oldString: "",
                newString: args.content,
                suppressInsertionStyle: true,
                theme: theme, width: width, stable: stable)
        default:
            return nil
        }
    }

    // MARK: - Single

    @MainActor
    private static func append(
        from single: SingleEntry,
        theme: TranscriptTheme,
        expandedUserBubbles: Set<AnyHashable>,
        into out: inout [TranscriptRow]
    ) {
        switch single.payload {
        case .localUser(let input):
            if let text = input.text, !text.isEmpty {
                let row = UserBubbleRow(text: text, theme: theme, stable: single.id)
                row.isExpanded = expandedUserBubbles.contains(single.id)
                out.append(row)
            }
            return

        case .remote(let message):
            switch message {
            case .user(let u):
                if let text = userPlainText(u), !text.isEmpty {
                    let row = UserBubbleRow(text: text, theme: theme, stable: single.id)
                    row.isExpanded = expandedUserBubbles.contains(single.id)
                    out.append(row)
                }
                // tool_result / image-only / empty → skip
            case .assistant(let a):
                appendAssistant(
                    blocks: a.message?.content ?? [],
                    entryId: single.id,
                    theme: theme,
                    into: &out)
            default:
                break  // system / result / unknown → not rendered
            }
        }
    }

    /// Walk assistant blocks in order, merging adjacent text blocks into one
    /// `AssistantMarkdownRow` and emitting a `PlaceholderRow` for each
    /// tool_use. Thinking / unknown blocks are ignored.
    @MainActor
    private static func appendAssistant(
        blocks: [Message2AssistantMessageContent],
        entryId: UUID,
        theme: TranscriptTheme,
        into out: inout [TranscriptRow]
    ) {
        var textBuffer: [String] = []
        var textStartIndex = 0

        func flushText(endIndex: Int) {
            guard !textBuffer.isEmpty else { return }
            let source = textBuffer.joined(separator: "\n\n")
            textBuffer.removeAll()
            out.append(AssistantMarkdownRow(
                source: source,
                theme: theme,
                stable: "\(entryId.uuidString)-md-\(textStartIndex)" as String))
            textStartIndex = endIndex
        }

        for (idx, block) in blocks.enumerated() {
            switch block {
            case .text(let t):
                if let s = t.text, !s.isEmpty {
                    if textBuffer.isEmpty { textStartIndex = idx }
                    textBuffer.append(s)
                }
            case .toolUse(let u):
                flushText(endIndex: idx)
                let stableId: AnyHashable = "\(entryId.uuidString)-tool-\(idx)" as String
                if let row = toolUseDiffRow(u, theme: theme, stable: stableId) {
                    out.append(row)
                } else {
                    out.append(PlaceholderRow(
                        label: "[Tool: \(u.caseName)]",
                        theme: theme,
                        stable: stableId))
                }
            case .thinking, .unknown:
                continue
            }
        }
        flushText(endIndex: blocks.count)
    }

    /// @MainActor 对应的 Edit / Write 路由。同 `toolUseDiffItem` 但直接返回
    /// `DiffRow`（layout 延后到 makeSize 第一次被调）；input 不完整时回 nil，
    /// caller 退回 PlaceholderRow。
    @MainActor
    private static func toolUseDiffRow(
        _ u: ToolUse,
        theme: TranscriptTheme,
        stable: AnyHashable
    ) -> TranscriptRow? {
        switch u {
        case .Edit(let edit):
            guard let args = editDiffArgs(edit) else { return nil }
            let prepared = TranscriptPrepare.diff(
                filePath: args.filePath,
                oldString: args.oldString,
                newString: args.newString,
                suppressInsertionStyle: false,
                theme: theme,
                stable: stable)
            return DiffRow(prepared: prepared, theme: theme)
        case .Write(let write):
            guard let args = writeDiffArgs(write) else { return nil }
            let prepared = TranscriptPrepare.diff(
                filePath: args.filePath,
                oldString: "",
                newString: args.content,
                suppressInsertionStyle: true,
                theme: theme,
                stable: stable)
            return DiffRow(prepared: prepared, theme: theme)
        default:
            return nil
        }
    }

    // MARK: - User plaintext

    /// Concatenate visible text from Message2User's `.string` / `.array` content.
    /// Image / tool_result parts are ignored — user bubbles only show typed text.
    nonisolated private static func userPlainText(_ user: Message2User) -> String? {
        switch user.message?.content {
        case .string(let s)?:
            return s
        case .array(let items)?:
            let parts = items.compactMap { item -> String? in
                if case .text(let t) = item { return t.text }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        default:
            return nil
        }
    }
}

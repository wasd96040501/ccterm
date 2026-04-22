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

    nonisolated private static func cachedOrBuildUser(
        text: String,
        theme: TranscriptTheme,
        width: CGFloat,
        isExpanded: Bool,
        stable: AnyHashable
    ) -> TranscriptPreparedItem {
        let contentHash = userContentHash(text: text, theme: theme)
        let key = TranscriptPrepareCache.Key(
            contentHash: contentHash,
            widthBucket: TranscriptPrepareCache.widthBucket(width),
            variant: .user(isExpanded: isExpanded))
        if let cached = TranscriptPrepareCache.shared.get(key) {
            return cached.withStableId(stable)
        }
        let prepared = TranscriptPrepare.user(text: text, theme: theme, stable: stable)
        let layout = TranscriptPrepare.layoutUser(
            text: prepared.text, theme: theme,
            width: width, isExpanded: isExpanded)
        let item: TranscriptPreparedItem = .user(prepared, layout, isExpanded: isExpanded)
        TranscriptPrepareCache.shared.put(key, item)
        return item
    }

    nonisolated private static func cachedOrBuildAssistant(
        source: String,
        theme: TranscriptTheme,
        width: CGFloat,
        stable: AnyHashable
    ) -> TranscriptPreparedItem {
        let contentHash = assistantContentHash(source: source, theme: theme)
        let key = TranscriptPrepareCache.Key(
            contentHash: contentHash,
            widthBucket: TranscriptPrepareCache.widthBucket(width),
            variant: .assistant)
        if let cached = TranscriptPrepareCache.shared.get(key) {
            return cached.withStableId(stable)
        }
        let prepared = TranscriptPrepare.assistant(
            source: source, theme: theme, stable: stable)
        let layout = TranscriptPrepare.layoutAssistant(
            prebuilt: prepared.prebuilt, theme: theme, width: width)
        let item: TranscriptPreparedItem = .assistant(prepared, layout)
        // Plain item cached here; the highlight pass will overwrite with a
        // colored version once tokens are available.
        TranscriptPrepareCache.shared.put(key, item)
        return item
    }

    nonisolated private static func cachedOrBuildPlaceholder(
        label: String,
        theme: TranscriptTheme,
        stable: AnyHashable
    ) -> TranscriptPreparedItem {
        // Placeholder layout is width-independent — use a sentinel width
        // bucket so all widths share the same cache slot.
        let contentHash = placeholderContentHash(label: label, theme: theme)
        let key = TranscriptPrepareCache.Key(
            contentHash: contentHash,
            widthBucket: 0,
            variant: .placeholder)
        if let cached = TranscriptPrepareCache.shared.get(key) {
            return cached.withStableId(stable)
        }
        let prepared = TranscriptPrepare.placeholder(
            label: label, theme: theme, stable: stable)
        let layout = TranscriptPrepare.layoutPlaceholder(
            label: prepared.label, theme: theme)
        let item: TranscriptPreparedItem = .placeholder(prepared, layout)
        TranscriptPrepareCache.shared.put(key, item)
        return item
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
                out.append(cachedOrBuildPlaceholder(
                    label: "[Tool: \(u.caseName)]", theme: theme, stable: stableId))
            case .thinking, .unknown:
                continue
            }
        }
        flushText(endIndex: blocks.count)
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
                out.append(PlaceholderRow(
                    label: "[Tool: \(u.caseName)]",
                    theme: theme,
                    stable: "\(entryId.uuidString)-tool-\(idx)" as String))
            case .thinking, .unknown:
                continue
            }
        }
        flushText(endIndex: blocks.count)
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

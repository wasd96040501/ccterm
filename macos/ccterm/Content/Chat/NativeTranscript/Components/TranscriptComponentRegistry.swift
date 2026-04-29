import AgentSDK
import AppKit

/// 已注册的 component 集合 + builder 操作。新增 component:加一行 `inputs(...)`
/// dispatch 即可,无需改 controller / cache / pipeline 主干。
nonisolated enum TranscriptComponentRegistry {

    /// Walk all components for this entry, return their inputs paired with the
    /// erased prepare/layout/cache pipeline.
    static func inputsAndItems(
        from entry: MessageEntry,
        entryIndex: Int,
        entryCount: Int,
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable]
    ) -> [AnyPreparedItem] {
        var out: [AnyPreparedItem] = []

        // Each component picks its own inputs from the entry. inputs() returns []
        // when the entry doesn't concern that component (no exclusivity).
        for input in GroupComponent.inputs(
            from: entry, entryIndex: entryIndex, entryCount: entryCount
        ) {
            out.append(prepareAndLayout(
                GroupComponent.self, identified: input,
                theme: theme, width: width,
                stickyStates: stickyStates))
        }
        for input in PlaceholderComponent.inputs(
            from: entry, entryIndex: entryIndex, entryCount: entryCount
        ) {
            out.append(prepareAndLayout(
                PlaceholderComponent.self, identified: input,
                theme: theme, width: width,
                stickyStates: stickyStates))
        }
        for input in UserBubbleComponent.inputs(
            from: entry, entryIndex: entryIndex, entryCount: entryCount
        ) {
            out.append(prepareAndLayout(
                UserBubbleComponent.self, identified: input,
                theme: theme, width: width,
                stickyStates: stickyStates))
        }
        for input in AssistantMarkdownComponent.inputs(
            from: entry, entryIndex: entryIndex, entryCount: entryCount
        ) {
            out.append(prepareAndAssistant(
                identified: input,
                theme: theme, width: width,
                stickyStates: stickyStates))
        }

        // Sort by (entryIndex, blockIndex) to honor block order within an entry.
        out.sort { ($0.entryIndex, $0.blockIndex) < ($1.entryIndex, $1.blockIndex) }
        return out
    }

    /// 单 entry → 多 item 的 fully-walked 入口。Builder 多 entry 路径调用方累加。
    static func itemsForEntry(
        _ entry: MessageEntry,
        entryIndex: Int,
        entryCount: Int,
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable]
    ) -> [AnyPreparedItem] {
        inputsAndItems(
            from: entry, entryIndex: entryIndex, entryCount: entryCount,
            theme: theme, width: width, stickyStates: stickyStates)
    }

    // MARK: - Generic prepare-and-layout pipeline

    private static func prepareAndLayout<C: TranscriptComponent>(
        _ type: C.Type,
        identified: IdentifiedInput<C.Input>,
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable]
    ) -> AnyPreparedItem {
        let contentHash = C.contentHash(identified.input, theme: theme)
        let cacheKey = TranscriptPrepareCache.Key(contentHash: contentHash, tag: C.tag)

        let content: C.Content
        if let cached = TranscriptPrepareCache.shared.get(cacheKey),
           let typed = cached.contentAs(C.self) {
            content = typed
        } else {
            content = C.prepare(identified.input, theme: theme)
            TranscriptPrepareCache.shared.put(
                cacheKey, .init(tag: C.tag, content: content))
        }

        let state = (stickyStates[identified.stableId] as? C.State) ?? C.initialState(for: identified.input)
        let layout = C.layout(content, theme: theme, width: width, state: state)

        let item = PreparedItem<C>(
            stableId: identified.stableId,
            input: identified.input,
            content: content,
            contentHash: contentHash,
            state: state,
            layout: layout)

        return AnyPreparedItem.erase(
            item,
            entryIndex: identified.entryIndex,
            blockIndex: identified.blockIndex,
            layoutWidth: width)
    }

    /// Assistant 专用 — 注入 highlight provider + token applier(其他 component
    /// 没 refinement 不需要)。
    private static func prepareAndAssistant(
        identified: IdentifiedInput<AssistantMarkdownComponent.Input>,
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable]
    ) -> AnyPreparedItem {
        typealias C = AssistantMarkdownComponent
        let contentHash = C.contentHash(identified.input, theme: theme)
        let cacheKey = TranscriptPrepareCache.Key(contentHash: contentHash, tag: C.tag)

        let content: C.Content
        if let cached = TranscriptPrepareCache.shared.get(cacheKey),
           let typed = cached.contentAs(C.self) {
            content = typed
        } else {
            content = C.prepare(identified.input, theme: theme)
            TranscriptPrepareCache.shared.put(
                cacheKey, .init(tag: C.tag, content: content))
        }

        let state = (stickyStates[identified.stableId] as? C.State) ?? C.initialState(for: identified.input)
        let layout = C.layout(content, theme: theme, width: width, state: state)
        let item = PreparedItem<C>(
            stableId: identified.stableId,
            input: identified.input,
            content: content,
            contentHash: contentHash,
            state: state,
            layout: layout)

        return AnyPreparedItem.erase(
            item,
            entryIndex: identified.entryIndex,
            blockIndex: identified.blockIndex,
            layoutWidth: width,
            highlightProvider: { item in
                C.highlightRequests(item)
            },
            tokenApplier: { item, tokens, theme, width in
                C.applyTokens(item, tokens: tokens, theme: theme, width: width)
            })
    }
}

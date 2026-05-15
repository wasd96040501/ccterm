import AppKit

/// `PreparedItem<C>` 的 type-erased 载体 —— builder / pipeline / cache 持有
/// 异构 `[AnyPreparedItem]` 时用。和 `ComponentRow`(MainActor type-erase)相对,
/// `AnyPreparedItem` 是 Sendable off-main 载体。
///
/// 全部操作通过 `@Sendable` 闭包折返到具体 `C`;调用方零 `as?`。
struct AnyPreparedItem: @unchecked Sendable {
    let stableId: StableId
    /// 入口下标(entries 数组里这条 item 源自第几条 entry)。
    let entryIndex: Int
    /// 源 block 在 entry 内的下标 —— 多条 input 来自同 entry 时用来稳定 merge 排序。
    let blockIndex: Int
    /// `C.tag`。NSTableView reuse + cache bucket 用。
    let tag: String
    let contentHash: Int
    let cachedHeight: CGFloat
    let cacheKey: TranscriptPrepareCache.Key

    /// 这个 item 的 layout 是在哪个 width 下算的 —— 给 ComponentRow.cachedSize.width 用。
    let layoutWidth: CGFloat

    private let _makeRow: @MainActor @Sendable (TranscriptTheme) -> ComponentRow
    private let _withStableId: @Sendable (StableId) -> AnyPreparedItem
    private let _strippingLayout: @Sendable () -> AnyPreparedItem
    private let _relayoutForWidth: @Sendable (CGFloat, TranscriptTheme) -> AnyPreparedItem
    private let _highlightRequests: @Sendable () -> [AnyHighlightRequest]
    private let _applyingTokens: @Sendable (
        [AnyHashable: [SyntaxToken]], TranscriptTheme, CGFloat
    ) -> AnyPreparedItem

    @MainActor func makeRow(theme: TranscriptTheme) -> ComponentRow {
        _makeRow(theme)
    }
    func withStableId(_ newId: StableId) -> AnyPreparedItem { _withStableId(newId) }
    func strippingLayout() -> AnyPreparedItem { _strippingLayout() }
    func relayoutForWidth(_ width: CGFloat, theme: TranscriptTheme) -> AnyPreparedItem {
        _relayoutForWidth(width, theme)
    }
    func highlightRequests() -> [AnyHighlightRequest] { _highlightRequests() }
    func applyingTokens(
        _ tokens: [AnyHashable: [SyntaxToken]],
        theme: TranscriptTheme,
        width: CGFloat
    ) -> AnyPreparedItem {
        _applyingTokens(tokens, theme, width)
    }

    // MARK: - Factory

    /// 从具体 `PreparedItem<C>` erase 成 `AnyPreparedItem`。Builder / cache 路径
    /// 调这个。
    ///
    /// `highlightProvider` / `tokenApplier` 可选 —— 仅 Assistant 类型需要。
    /// 其他 component 用默认空实现(无 refinement 请求)。
    static func erase<C: TranscriptComponent>(
        _ item: PreparedItem<C>,
        entryIndex: Int,
        blockIndex: Int,
        layoutWidth: CGFloat,
        highlightProvider: (@Sendable (PreparedItem<C>) -> [AnyHighlightRequest])? = nil,
        tokenApplier: (@Sendable (
            PreparedItem<C>, [AnyHashable: [SyntaxToken]], TranscriptTheme, CGFloat
        ) -> PreparedItem<C>)? = nil
    ) -> AnyPreparedItem {
        AnyPreparedItem(
            stableId: item.stableId,
            entryIndex: entryIndex,
            blockIndex: blockIndex,
            tag: C.tag,
            contentHash: item.contentHash,
            cachedHeight: item.cachedHeight,
            cacheKey: item.cacheKey,
            layoutWidth: layoutWidth,
            _makeRow: { @MainActor @Sendable theme in
                item.makeRow(theme: theme, layoutWidth: layoutWidth)
            },
            _withStableId: { @Sendable newId in
                .erase(
                    item.withStableId(newId),
                    entryIndex: entryIndex,
                    blockIndex: blockIndex,
                    layoutWidth: layoutWidth,
                    highlightProvider: highlightProvider,
                    tokenApplier: tokenApplier)
            },
            _strippingLayout: { @Sendable in
                .erase(
                    item.strippingLayout(),
                    entryIndex: entryIndex,
                    blockIndex: blockIndex,
                    layoutWidth: layoutWidth,
                    highlightProvider: highlightProvider,
                    tokenApplier: tokenApplier)
            },
            _relayoutForWidth: { @Sendable newWidth, theme in
                let newLayout = C.layout(
                    item.content,
                    theme: theme,
                    width: newWidth,
                    state: item.state)
                let relayouted = item.withLayout(newLayout)
                return .erase(
                    relayouted,
                    entryIndex: entryIndex,
                    blockIndex: blockIndex,
                    layoutWidth: newWidth,
                    highlightProvider: highlightProvider,
                    tokenApplier: tokenApplier)
            },
            _highlightRequests: { @Sendable in
                highlightProvider?(item) ?? []
            },
            _applyingTokens: { @Sendable tokens, theme, width in
                guard let applier = tokenApplier else {
                    return .erase(
                        item,
                        entryIndex: entryIndex,
                        blockIndex: blockIndex,
                        layoutWidth: layoutWidth,
                        highlightProvider: highlightProvider,
                        tokenApplier: tokenApplier)
                }
                let updated = applier(item, tokens, theme, width)
                return .erase(
                    updated,
                    entryIndex: entryIndex,
                    blockIndex: blockIndex,
                    layoutWidth: width,
                    highlightProvider: highlightProvider,
                    tokenApplier: tokenApplier)
            }
        )
    }
}

/// Component 自报的一条 highlight 请求。`innerKey` 是 component 内部 schema
/// 的识别符(Assistant 用 `segmentIndex: Int`),framework 在 batch 回填时原样
/// 透传回 `applyingTokens(_:)`。
struct AnyHighlightRequest: Sendable {
    let code: String
    let language: String?
    let innerKey: AnyHashable
}

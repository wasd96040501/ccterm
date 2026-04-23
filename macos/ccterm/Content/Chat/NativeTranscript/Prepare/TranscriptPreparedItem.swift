import AppKit

/// 一条 prepared row 的通用接口——controller / cache / builder 对"row 是哪种
/// 具体类型"不 care，走协议方法 dispatch。
///
/// 每种具体 row 一个 struct（`AssistantPreparedItem` / `UserPreparedItem` /
/// `PlaceholderPreparedItem` / 未来 `ToolBlockPreparedItem`），持有自己的
/// `Prepared`（宽度无关 content）+ `LayoutData`（宽度相关排版）。
///
/// 新增 row 类型 = 新建一个 `*PreparedItem.swift`，不用动 controller / cache /
/// builder 主流程。唯一需要动的注册点是 `TranscriptRowBuilder` 里 `entry →
/// preparedItem` 的入口工厂 switch（和 Telegram 的同类注册点对齐）。
protocol TranscriptPreparedItem: Sendable {
    /// Diff / scroll anchor / expansion tracking 用。
    var stableId: AnyHashable { get }

    /// 同 stableId 下内容是否变化的指纹，驱动 row carry-over。
    var contentHash: Int { get }

    /// 宽度相关排版后的 row 高度。在 cache 里（layout 未设置）时为 0。
    /// controller 读它喂 `heightOfRow`——永远等于后续 `row.cachedHeight`
    /// （by construction，因为 layout 是精确 width 算的）。
    var cachedHeight: CGFloat { get }

    /// Content-only cache key（width-independent）。cache 里全部以此为键。
    var cacheKey: TranscriptPrepareCache.Key { get }

    /// 主线程工厂——把 prepared + layout 包成一个活 `TranscriptRow`。
    @MainActor
    func makeRow(theme: TranscriptTheme) -> TranscriptRow

    /// 返回一个同类型副本，`stableId` 换成 `newId`。cache 命中时由调用方调这个
    /// 把 cached 的老 id 换成当前 session 的新 id（否则 `TranscriptDiff.compute`
    /// 匹配不上）。
    func withStableId(_ newId: AnyHashable) -> any TranscriptPreparedItem

    /// 返回一个同类型副本，layout 字段清空——只剩 content（Prepared）。cache
    /// put 前调这个减少存储。再次使用时由调用方调类型专属的 "relayouted" 重新
    /// 排版。
    func strippingLayout() -> any TranscriptPreparedItem

    // MARK: - Async refinements（默认空实现；Assistant 覆盖）
    //
    // Phase A 先把 highlight 从 +Pipeline 的 switch 中抽到协议上。Phase B 再
    // 进一步抽成 `RowRefinementWork` 通用通道，这两个方法届时会被删除。

    /// 本 item 有哪些代码段需要 syntax highlight。`innerKey` 是 row 自己选的
    /// 内部索引（Assistant 今天用 `segmentIndex: Int`）；controller 不 care。
    func highlightRequests() -> [(code: String, language: String?, innerKey: AnyHashable)]

    /// 吃回一批 tokens，产新的 item（新的 prebuilt + 新的 layout）。controller
    /// 在 highlight batch 完成后调这个回灌。width 参数允许重新做宽度相关排版。
    func applyingTokens(
        _ tokens: [AnyHashable: [SyntaxToken]],
        theme: TranscriptTheme,
        width: CGFloat
    ) -> any TranscriptPreparedItem
}

extension TranscriptPreparedItem {
    func highlightRequests() -> [(code: String, language: String?, innerKey: AnyHashable)] {
        []
    }

    func applyingTokens(
        _: [AnyHashable: [SyntaxToken]],
        theme _: TranscriptTheme,
        width _: CGFloat
    ) -> any TranscriptPreparedItem {
        self
    }
}

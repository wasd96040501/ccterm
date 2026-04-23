import AppKit

/// Placeholder row（tool 占位 / group 提示）的 prepared item。
/// layout 宽度无关（固定高度），构造一次即可重用——但为了协议统一，仍放在
/// `strippingLayout` 可清空的字段里。
struct PlaceholderPreparedItem: TranscriptPreparedItem, @unchecked Sendable {
    let prepared: PlaceholderPrepared
    let layout: PlaceholderLayoutData?

    var stableId: AnyHashable { prepared.stable }
    var contentHash: Int { prepared.contentHash }
    var cachedHeight: CGFloat { layout?.cachedHeight ?? 0 }
    var cacheKey: TranscriptPrepareCache.Key {
        TranscriptPrepareCache.Key(contentHash: prepared.contentHash, variant: .placeholder)
    }

    @MainActor
    func makeRow(theme: TranscriptTheme) -> TranscriptRow {
        let r = PlaceholderRow(prepared: prepared, theme: theme)
        if let layout { r.applyLayout(layout) }
        return r
    }

    func withStableId(_ newId: AnyHashable) -> any TranscriptPreparedItem {
        Self(
            prepared: PlaceholderPrepared(
                label: prepared.label,
                stable: newId,
                contentHash: prepared.contentHash),
            layout: layout)
    }

    func strippingLayout() -> any TranscriptPreparedItem {
        Self(prepared: prepared, layout: nil)
    }
}

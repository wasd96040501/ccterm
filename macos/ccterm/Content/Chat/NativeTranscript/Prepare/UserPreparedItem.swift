import AppKit

/// User bubble row 的 prepared item。content = `UserPrepared`（text + hash），
/// layout = `UserLayoutData`（带 `lastLayoutExpanded` 作输入快照）。
///
/// `isExpanded` 不存字段——它通过 `layout.lastLayoutExpanded` 隐式携带
/// （layoutUser 按 isExpanded 算出不同 bubbleHeight）。cache 存的 stripped
/// 版本 layout 为 nil，下游 builder 读 controller 的 `expandedUserBubbles` 集
/// 重算 layout。
struct UserPreparedItem: TranscriptPreparedItem, @unchecked Sendable {
    let prepared: UserPrepared
    let layout: UserLayoutData?

    var stableId: AnyHashable { prepared.stable }
    var contentHash: Int { prepared.contentHash }
    var cachedHeight: CGFloat { layout?.cachedHeight ?? 0 }
    var cacheKey: TranscriptPrepareCache.Key {
        TranscriptPrepareCache.Key(contentHash: prepared.contentHash, variant: .user)
    }

    @MainActor
    func makeRow(theme: TranscriptTheme) -> TranscriptRow {
        let r = UserBubbleRow(prepared: prepared, theme: theme)
        if let layout {
            r.isExpanded = layout.lastLayoutExpanded
            r.applyLayout(layout)
        }
        return r
    }

    func withStableId(_ newId: AnyHashable) -> any TranscriptPreparedItem {
        Self(
            prepared: UserPrepared(
                text: prepared.text,
                stable: newId,
                contentHash: prepared.contentHash),
            layout: layout)
    }

    func strippingLayout() -> any TranscriptPreparedItem {
        Self(prepared: prepared, layout: nil)
    }
}

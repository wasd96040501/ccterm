import AppKit

/// Assistant markdown row 的 prepared item。content = `AssistantPrepared`
/// （parse + prebuilt），layout = `AssistantLayoutData`（width-aware rendered
/// segments）。
///
/// Highlight 是 Assistant 专有能力——这里覆盖 `highlightRequests()` 和
/// `applyingTokens(_:theme:width:)` 的默认实现。其他类型不碰。
struct AssistantPreparedItem: TranscriptPreparedItem, @unchecked Sendable {
    let prepared: AssistantPrepared
    /// `nil` = 在 cache 里（`strippingLayout` 过）或刚构造未排版。使用前必须
    /// `relayouted(width:theme:)` 或由 builder 喂入带 layout 的实例。
    let layout: AssistantLayoutData?

    var stableId: AnyHashable { prepared.stable }
    var contentHash: Int { prepared.contentHash }
    var cachedHeight: CGFloat { layout?.cachedHeight ?? 0 }
    var cacheKey: TranscriptPrepareCache.Key {
        TranscriptPrepareCache.Key(contentHash: prepared.contentHash, variant: .assistant)
    }

    @MainActor
    func makeRow(theme: TranscriptTheme) -> TranscriptRow {
        let r = AssistantMarkdownRow(prepared: prepared, theme: theme)
        if let layout { r.applyLayout(layout) }
        return r
    }

    func withStableId(_ newId: AnyHashable) -> any TranscriptPreparedItem {
        Self(
            prepared: AssistantPrepared(
                source: prepared.source,
                parsedDocument: prepared.parsedDocument,
                prebuilt: prepared.prebuilt,
                stable: newId,
                contentHash: prepared.contentHash,
                hasHighlight: prepared.hasHighlight),
            layout: layout)
    }

    func strippingLayout() -> any TranscriptPreparedItem {
        Self(prepared: prepared, layout: nil)
    }

    // MARK: - Highlight

    /// 从 parsed markdown 扫出所有 code block，返回 highlight engine 的请求。
    /// `innerKey = segmentIndex: Int`——`applyTokens` 按这个 key 回灌到对应
    /// segment 的 prebuilt。
    func highlightRequests() -> [(code: String, language: String?, innerKey: AnyHashable)] {
        guard !prepared.hasHighlight else { return [] }
        var out: [(code: String, language: String?, innerKey: AnyHashable)] = []
        for (segIdx, seg) in prepared.parsedDocument.segments.enumerated() {
            if case .codeBlock(let block) = seg {
                out.append((block.code, block.language, AnyHashable(segIdx)))
            }
        }
        return out
    }

    /// 回灌：重 build prebuilt（带彩色 tokens）→ 重跑 layout。
    /// 只消化 `Int` key 的 tokens（对应 segmentIndex）；其他 key 忽略。
    func applyingTokens(
        _ tokens: [AnyHashable: [SyntaxToken]],
        theme: TranscriptTheme,
        width: CGFloat
    ) -> any TranscriptPreparedItem {
        var codeTokens: [Int: [SyntaxToken]] = [:]
        for (key, value) in tokens {
            if let i = key.base as? Int { codeTokens[i] = value }
        }
        let newPrebuilt = MarkdownRowPrebuilder.build(
            document: prepared.parsedDocument,
            theme: theme,
            codeTokens: codeTokens)
        let newPrepared = AssistantPrepared(
            source: prepared.source,
            parsedDocument: prepared.parsedDocument,
            prebuilt: newPrebuilt,
            stable: prepared.stable,
            contentHash: prepared.contentHash,
            hasHighlight: true)
        let newLayout = TranscriptPrepare.layoutAssistant(
            prebuilt: newPrebuilt, theme: theme, width: width)
        return Self(prepared: newPrepared, layout: newLayout)
    }
}

import AppKit

/// `TranscriptController.setEntries` 每次会根据新旧 `lastEntriesSignature` 的
/// delta 形状决定滚动意图，对齐 Telegram macOS `TableScrollState`：
///
/// | delta 形状                               | intent                                |
/// | ---------------------------------------- | ------------------------------------- |
/// | empty → non-empty (首次打开 session)       | `.bottom`                             |
/// | old 是 new 的严格前缀 (pure append)         | `.preserve`                           |
/// | old 是 new 的严格后缀 (pure prepend)        | `.anchor(rows[0].stableId, topOffset)` |
/// | 其它 (theme 变化 / tool_result resolve 等)  | `.preserve`                           |
///
/// intent 完全是 controller 内部派生量，不进 `setEntries` 签名 —— 外部调用点零改动。
enum TranscriptScrollIntent: Equatable {
    /// 维持当前 clipView origin 不动。任何本地、视觉上不期望跳动的 setEntries 都用它。
    case preserve

    /// 把 clipView origin 置到内容最底部（Telegram `.down` 语义）。
    /// 专供「首帧 paint」场景。
    case bottom

    /// 保持某个已挂载行的 top offset 不变。Phase 2 prepend / `.loaded` 合并时使用，
    /// 等价 Telegram `TableScrollState.saveVisible(.upper, animated: false)`。
    ///
    /// - `stableId`: capture 时刻某一 row 的 stableId（通常是 rows[0]，即将被 prepend 的锚）
    /// - `topOffset`: capture 时该行 `rect.minY - clip.bounds.minY`
    case anchor(stableId: AnyHashable, topOffset: CGFloat)

    /// 精简 tag 给日志用（`preserve` / `bottom` / `anchor`）——日志别带 stableId
    /// 避免 PII 和字符串爆炸。
    var logTag: String {
        switch self {
        case .preserve: return "preserve"
        case .bottom:   return "bottom"
        case .anchor:   return "anchor"
        }
    }
}

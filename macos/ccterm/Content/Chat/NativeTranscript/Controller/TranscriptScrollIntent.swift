import AppKit

/// `TranscriptController` 内部 scroll 意图，对应 Telegram macOS `TableScrollState`
/// 里会被 ccterm 用到的子集（`.saveVisible(.upper)` / `.down` / `.none`）。
///
/// 由 caller 通过 `TranscriptUpdateReason` 决定 intent 来自哪个枚举值；controller
/// **不**从 entries delta 形状去推断。
enum TranscriptScrollIntent: Equatable {
    /// 维持当前 clipView origin 不动。`.update` / `.liveAppend` / `.themeChange`
    /// 场景使用——任何本地、视觉上不期望跳动的 merge 都用它。
    case preserve

    /// 把 clipView origin 置到内容最底部（Telegram `.down` 语义）。
    /// 专供 `.initialPaint` 的 Phase 1 首帧使用。
    case bottom

    /// 保持某个已挂载行的 top offset 不变。`.initialPaint` 的 Phase 2 前插 /
    /// `.prependHistory` 合并时使用，等价 Telegram `saveVisible(.upper, false)`。
    ///
    /// - `stableId`: capture 时刻某一 row 的 stableId（通常是 rows[0]，即将被
    ///   prepend 的锚）
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

import AppKit
import Foundation

/// session 切走又切回来时恢复 scroll 的锚点。保存的是「离开时顶部可见 row 对应
/// 的 MessageEntry.id + 该 row 相对 viewport 顶端的 y 偏移」。
///
/// 粒度是 **entry 级**（不是 row 级）：一条 assistant 消息可能展开成多条 row
/// （md / tool / md 交替），这里只记录它们的源 entry——足够还原「我之前看到哪条
/// 消息在屏幕上方」，且避免 assistant 的合成 stableId（`"uuid-md-N"`）跨 session
/// 重建时匹配困难。
///
/// 对齐 Telegram macOS `ChatInterfaceHistoryScrollState`（`messageIndex` +
/// `relativeOffset`）：storage 层持有，view 层捕获/恢复。
///
/// `nil` 语义：用户离开时正好在内容末尾（bottom），下次回来直接 `.bottom`
/// 贴底即可——不用锚。Telegram 的 `immediateScrollState` 里 `.isDownOfHistory`
/// 特判返回 nil 同理。
struct SavedScrollAnchor: Equatable {
    let entryId: UUID
    let topOffset: CGFloat
}

/// 视图层意图枚举。每次 `SessionHandle2.snapshot` 更新携带一个 reason，告诉
/// transcript controller 这次变更是什么性质——controller 据此决定 viewport-first
/// pipeline 与 scroll 语义，不再从 entries delta 形状去推断意图。
///
/// 对齐 Telegram macOS `ChatHistoryViewUpdateType`（`.Initial` / `.Generic`）的
/// 分层：storage 层负责**语义**，view 层只做**渲染**。
enum TranscriptUpdateReason: Equatable {
    /// 初始占位：handle 刚构造、尚未 `loadHistory` / 首条 `receive`。messages
    /// 为空，controller 短路返回。
    case idle

    /// Session 首次打开的首帧：`loadHistory` Phase A 读完末尾 N 行，messages
    /// 非空。Controller 走 viewport-first tail，Phase 2 scroll `.bottom`。
    case initialPaint

    /// Phase B prefix 前插完成。delta 形状为 pure prepend；scroll 语义
    /// `.anchor(rows[0])`，保住用户当前首帧可见位置（= Telegram `saveVisible(.upper)`）。
    case prependHistory

    /// SDK streaming 新消息：live `receive(.append)`，或本地 `enqueueAndSend`
    /// 写入 `.queued` entry。末尾追加；scroll `.preserve`（贴底逻辑交给外层
    /// scroll hint；controller 不自动翻页）。
    case liveAppend

    /// mid-array 内容变化：tool_result 合入、queued→confirmed、queued→failed、
    /// cancelMessage 删除一条。scroll `.preserve`。
    case update
}

/// Transcript 视图层的唯一消费契约。SwiftUI 侧绑定 `handle.snapshot`（而不是
/// `handle.messages`），每次 `snapshot` 写入触发 `updateNSView` → controller
/// `setEntries(snapshot.messages, reason: snapshot.reason)`。
///
/// `revision` 是 handle 内部单调计数；即使某次 mutation 没有改变 messages 数组
/// 内容（例如 update 里原地替换 entry、但下标不变），revision 也会递增，保证
/// `@Observable` 追踪器看到写入。
struct TranscriptSnapshot: Equatable {
    let messages: [MessageEntry]
    let reason: TranscriptUpdateReason
    /// 仅 `.initialPaint` 消费：若 stableId 在当前 entries 内，则 viewport-first
    /// 围绕 anchor 展开并 scroll `.anchor(hint)`；若不在（entries 变化 / 首次
    /// 打开 / session 刚 load）则 fallback 到 tail + `.bottom`。其他 reason
    /// 忽略此字段。
    let scrollHint: SavedScrollAnchor?
    let revision: UInt64

    static let initial = TranscriptSnapshot(
        messages: [], reason: .idle, scrollHint: nil, revision: 0)

    // Equatable 对 MessageEntry 的 deep-compare 在 live 场景开销过大。
    // snapshot 比较语义用 revision 足矣—— revision 唯一标识一次 emit。
    static func == (lhs: TranscriptSnapshot, rhs: TranscriptSnapshot) -> Bool {
        lhs.revision == rhs.revision
    }
}

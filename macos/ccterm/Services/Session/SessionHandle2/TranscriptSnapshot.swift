import Foundation

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
    let revision: UInt64

    static let initial = TranscriptSnapshot(
        messages: [], reason: .idle, revision: 0)

    // Equatable 对 MessageEntry 的 deep-compare 在 live 场景开销过大。
    // snapshot 比较语义用 revision 足矣—— revision 唯一标识一次 emit。
    static func == (lhs: TranscriptSnapshot, rhs: TranscriptSnapshot) -> Bool {
        lhs.revision == rhs.revision
    }
}

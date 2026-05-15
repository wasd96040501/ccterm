import Foundation

/// Per-mutation 命令式信号。`SessionHandle2` 在每个写 messages 的点同步发出
/// 一条 `MessagesChange`，描述「**刚刚发生了什么**」（不是「现在是什么状态」）。
///
/// 设计意图：让 view bridge 不必扫整张 messages 表算 diff —— 直接根据 case
/// 翻译成 `Transcript2Controller.apply(.insert / .remove / .update)` 或
/// `loadInitial(...)`。
///
/// 通道形态：handle 暴露 `onMessagesChange: ((MessagesChange) -> Void)?`
/// 同步闭包；bridge 在 `attach(to:)` 里挂钩。AppKit 渲染端唯一的 outgoing
/// sink —— 同步触发保证 mutation 与 controller.apply 在同一调用栈完成，无
/// AsyncStream / @Observable 的额外 hop。SwiftUI 渲染端读 handle 的
/// `@Observable` 字段（`messages` / `status` / `isRunning` 等），不复用这条
/// 通道。
enum MessagesChange {
    /// 全量替换 view 端 timeline（`loadHistory` Phase A 完成 / `.loaded`
    /// 二次进入）。
    case reset([MessageEntry])
    /// 末尾追加一条新 entry。
    case appended(MessageEntry)
    /// 头部前插一组 entries（`loadHistory` Phase B prefix）。
    case prepended([MessageEntry])
    /// 替换一条已存在的 entry（tool_result merge / queued→confirmed /
    /// queued→failed / group items 增长）。`entry.id` 是 view 端定位用的 key。
    case updated(MessageEntry)
    /// 移除一条 entry（`cancelMessage`）。完整 entry 透传 —— bridge 用 entry
    /// 内容推导出本端缓存的 block ids，避免维护反向 map。
    case removed(MessageEntry)
}

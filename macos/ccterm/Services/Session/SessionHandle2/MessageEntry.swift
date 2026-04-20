import Foundation
import AgentSDK

struct MessageEntry: Identifiable {
    let id: UUID
    let message: Message2
    var delivery: DeliveryState?
    var toolResults: [String: ItemToolResult]
}

/// User entry 生命周期。
///
/// - `queued`：本地已 append，尚未收到 CLI 的 user echo（可能 CLI 还没起、还在 bootstrap、
///   或 CLI 忙着处理前面的 turn，消息还在 CLI 侧排队）。
/// - `confirmed`：CLI 已回显同 uuid 的 user 消息，turn 已真正开始处理。
/// - `failed`：进程退出等不可恢复错误，UI 可提示用户。
///
/// 非 user entry 的 `delivery` 恒为 nil。
enum DeliveryState: Equatable {
    case queued
    case confirmed
    case failed(reason: String)
}

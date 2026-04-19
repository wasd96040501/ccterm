import Foundation
import AgentSDK

// MARK: - Messaging commands

extension SessionHandle2 {

    /// 中断当前模型响应。仅 `.responding` 有效；其他 status no-op。
    ///
    /// 流程：`.responding` → `.interrupting`（写 stdin）→ SDK ack → `.idle` + flush queue。
    /// ack 回调中同时把 `.inFlight` 的 user entry 标记为 `.delivered`
    /// （turn 已实质结束，只是模型响应被切短）。
    func interrupt() {
        guard status == .responding, let agentSession else {
            appLog(.info, "SessionHandle2", "interrupt() ignored — status=\(status) \(sessionId)")
            return
        }
        appLog(.info, "SessionHandle2", "interrupt() begin \(sessionId)")
        status = .interrupting
        agentSession.interrupt { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for i in self.messages.indices where self.messages[i].delivery == .inFlight {
                    self.messages[i].delivery = .delivered
                }
                self.status = .idle
                self.flushQueueIfNeeded()
                appLog(.info, "SessionHandle2", "interrupt() ack → idle \(self.sessionId)")
            }
        }
    }

    /// 取消一条用户消息。
    ///
    /// - entry.delivery 为 `.queued` / `.failed`：从 `messages` 数组移除。
    /// - `.inFlight` / `.delivered` / nil（非 user entry）：no-op。
    /// - id 不存在或 entry 不是 user：no-op。
    func cancelMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        guard case .user = messages[idx].message else { return }
        switch messages[idx].delivery {
        case .queued, .failed:
            messages.remove(at: idx)
        default:
            break
        }
    }
}

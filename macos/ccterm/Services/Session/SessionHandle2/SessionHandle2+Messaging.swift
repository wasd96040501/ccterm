import Foundation
import AgentSDK

// MARK: - Messaging commands

extension SessionHandle2 {

    /// 中断当前模型响应。仅 `.responding` 有效；其他 status no-op。
    ///
    /// 流程：`.responding` → `.interrupting`（写 stdin）→ SDK ack → `.idle`。
    /// 本地 entry delivery 不动——`.queued` 的那些消息已经写到 CLI stdin，
    /// 在 CLI 侧排队，interrupt 不会把它们吐回来。如果后续它们仍被处理并 echo，
    /// `receive` 会自然切 `.confirmed`；若 CLI 一并丢弃，则停留 `.queued`，
    /// 用户可以 `cancelMessage` 清掉。
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
                self.status = .idle
                appLog(.info, "SessionHandle2", "interrupt() ack → idle \(self.sessionId)")
            }
        }
    }

    /// 取消一条用户消息。
    ///
    /// - entry.delivery 为 `.queued` / `.failed`：从 `messages` 数组移除。
    /// - `.confirmed` / nil（非 user entry）：no-op。
    /// - id 不存在或 entry 不是 user：no-op。
    ///
    /// 注意：`.queued` 的消息可能已经写到 CLI stdin（CLI 侧排队中）。本地 remove
    /// 只抹去 UI entry，并不能让 CLI 不处理它；如果它之后还是被处理，CLI 会
    /// emit 一条孤立的 user echo（找不到本地 entry 匹配），此时 `receive`
    /// 会走 append 分支，当作新消息展示。这是已知妥协——真正的 remote cancel
    /// 需要 CLI 支持，目前没有。
    func cancelMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        guard case .single(let single) = messages[idx] else { return }
        let isUserEntry: Bool = {
            switch single.payload {
            case .localUser: return true
            case .remote(let m):
                if case .user = m { return true }
                return false
            }
        }()
        guard isUserEntry else { return }
        switch single.delivery {
        case .queued, .failed:
            messages.remove(at: idx)
            emitSnapshot(.update)
        default:
            break
        }
    }
}

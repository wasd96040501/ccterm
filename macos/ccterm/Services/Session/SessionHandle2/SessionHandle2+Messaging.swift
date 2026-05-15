import Foundation
import AgentSDK

// MARK: - Messaging commands

extension SessionHandle2 {

    /// 中断当前 turn。守卫用 `isRunning`(`pendingTurnCount > 0`),不再用
    /// `status == .responding` —— send() 入口同步 +1 pendingTurnCount,而 status
    /// 翻 `.responding` 要等 CLI echo 回来,中间 100-300ms 空窗 stop 按钮已经显示
    /// 但旧的 `.responding` 守卫会拦下,表现为"点了没用"。
    ///
    /// 副作用按"UI 立即可见"的顺序排:
    /// 1. `pendingTurnCount = 0`:isRunning 立即 false,bar 切回 send 态。
    /// 2. `.responding` → `.interrupting`(其他 status 保持不变,避免污染
    ///    `.starting` / `.idle` 这种"还没收到 echo" 的子态)。
    /// 3. 仍 `.queued` 的本地 user entry 标 failed,防止 bootstrap 完成后
    ///    `flushBootstrapBacklog` 把它们补发给 CLI(那样用户点了 stop 实际还是发出去了)。
    /// 4. agentSession 在场就发 RPC;不在场(bootstrap 还没到 attach)直接跳过 ——
    ///    没 CLI 连接就没有 turn 可中断,本地清理已经满足语义。
    func interrupt() {
        guard isRunning else {
            appLog(.info, "SessionHandle2", "interrupt() ignored — not running status=\(status) \(sessionId)")
            return
        }
        appLog(.info, "SessionHandle2", "interrupt() begin status=\(status) \(sessionId)")
        pendingTurnCount = 0
        if status == .responding {
            status = .interrupting
        }
        failQueuedEntries(reason: "interrupted")
        guard let agentSession else {
            appLog(.info, "SessionHandle2", "interrupt() no agentSession — local-only \(sessionId)")
            return
        }
        agentSession.interrupt { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.status == .interrupting {
                    self.status = .idle
                }
                appLog(.info, "SessionHandle2", "interrupt() ack \(self.sessionId)")
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
            let removed = messages.remove(at: idx)
            onMessagesChange?(.removed(removed))
        default:
            break
        }
    }
}

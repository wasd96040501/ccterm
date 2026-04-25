import Foundation
import Observation

/// `SessionHandle2` 的注册表 + 单一导航 source of truth（v2 栈）。
///
/// `current` 是当前展示给用户的 handle —— 历史会话和"新对话"在 v2 中没有二分,都是
/// 一个 `SessionHandle2`,只是 `status` 不同。所有 selection 切换走显式命令
/// (`select(_:)` / `startNewConversation()`),数据流单向:
///
///   user 命令 → manager → current 改 → SwiftUI track → view 渲染
///   user 输入 → handle.send(...) → handle 内部状态机(current 引用不变)
///
/// init 时立即创建一个 `.notStarted` 的空 handle 作为初始 `current`,window 一开就有
/// 输入栏可用。第一次 `send` 触发 handle 内部 `ensureStarted()` 自动 persist;
/// 此后这个 handle 就是普通历史会话,`startNewConversation()` 用户主动触发才会换新。
@Observable
@MainActor
final class SessionManager2 {

    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private var handles: [String: SessionHandle2] = [:]

    /// 当前展示的 handle。导航唯一字段。
    private(set) var current: SessionHandle2

    init(repository: SessionRepository = SessionRepository()) {
        self.repository = repository
        let fresh = SessionHandle2(sessionId: UUID().uuidString, repository: repository)
        self.handles = [fresh.sessionId: fresh]
        self.current = fresh
    }

    /// 切换到指定 sessionId 对应的 handle。命中缓存 → 直接换;db 有记录 → 懒创建并缓存;
    /// 都没有 → no-op(不建孤儿)。
    func select(_ sessionId: String) {
        if sessionId == current.sessionId { return }
        if let cached = handles[sessionId] {
            current = cached
            return
        }
        guard repository.find(sessionId) != nil else { return }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        handles[sessionId] = handle
        current = handle
    }

    /// 切到一个新对话。当前 `current` 已经是空 `.notStarted` handle 时复用——避免堆积
    /// 多个空 handle;否则新建一个并切过去。
    func startNewConversation() {
        if current.status == .notStarted, current.messages.isEmpty {
            return
        }
        let fresh = SessionHandle2(sessionId: UUID().uuidString, repository: repository)
        handles[fresh.sessionId] = fresh
        current = fresh
    }

    /// 按 `sessionId` 获取 `SessionHandle2`。db 无记录 → nil。首次调用懒创建并缓存。
    /// 历史浏览路径用,不切换 `current`。
    func session(_ sessionId: String) -> SessionHandle2? {
        if let handle = handles[sessionId] { return handle }
        guard repository.find(sessionId) != nil else { return nil }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        handles[sessionId] = handle
        return handle
    }

    /// 返回已缓存的 handle,否则 nil —— 不触发懒创建。hover prewarm 用。
    func existingSession(_ sessionId: String) -> SessionHandle2? {
        handles[sessionId]
    }

    /// 所有未归档的会话记录,按 `lastActiveAt` 降序。Sidebar v2 用。
    func allRecords() -> [SessionRecord] {
        repository.findAll()
    }
}

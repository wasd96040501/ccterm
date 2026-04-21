import Foundation
import Observation

/// `SessionHandle2` 的注册表（v2 栈）。当前只承担「只读浏览历史会话」所需的最小职责：
/// 按 `sessionId` 懒创建并缓存 `SessionHandle2`。不做 launch / stop / archive / pin，
/// 这些仍在老 `SessionService` 上；v2 会在后续步骤逐步接管。
///
/// 持有独立的 `SessionRepository` 实例，通过 `CoreDataStack.shared` 与老栈共享数据。
@Observable
@MainActor
final class SessionManager2 {

    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private var handles: [String: SessionHandle2] = [:]

    init(repository: SessionRepository = SessionRepository()) {
        self.repository = repository
    }

    /// 按 `sessionId` 获取 `SessionHandle2`。DB 无记录 → nil。
    /// 首次调用创建并缓存；后续返回同一实例（identity stable）。
    /// 只读浏览用，不启动子进程。
    func session(_ sessionId: String) -> SessionHandle2? {
        if let handle = handles[sessionId] { return handle }
        guard repository.find(sessionId) != nil else { return nil }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        handles[sessionId] = handle
        return handle
    }

    /// 所有未归档的会话记录，按 `lastActiveAt` 降序。Sidebar v2 用。
    func allRecords() -> [SessionRecord] {
        repository.findAll()
    }
}

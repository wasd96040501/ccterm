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

    /// 未归档的会话记录，按 `lastActiveAt` 降序。Sidebar v2 直接观察此数组渲染。
    /// 由 `refreshRecords()` 主动刷新；初始化时填充一次。
    private(set) var records: [SessionRecord] = []

    init(repository: SessionRepository = SessionRepository()) {
        self.repository = repository
        self.records = repository.findAll()
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

    /// 返回已缓存的 handle，否则 nil —— 不触发懒创建。
    /// 用于 hover prewarm 等路径：hover 不应凭空创建 handle，
    /// 只复用已被业务流程创建过的实例。
    func existingSession(_ sessionId: String) -> SessionHandle2? {
        handles[sessionId]
    }

    /// 为 NewSession draft 准备 handle。DB 必须**无**对应记录（identity 由 UI 新生成的 UUID 给出）。
    /// 与 `session(_:)` 的区别：不读 repository，纯 in-memory 构造；后续 `activate()` /
    /// `send(_:)` 触发 `ensureStarted` 时走 fresh 路径写 DB。
    func prepareDraft(_ sessionId: String) -> SessionHandle2 {
        if let handle = handles[sessionId] { return handle }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        handles[sessionId] = handle
        return handle
    }

    /// 重读 repository 全量记录并回写到 `records`。NewSession 启动后由调用方触发。
    func refreshRecords() {
        records = repository.findAll()
    }

    /// 所有未归档的会话记录，按 `lastActiveAt` 降序。Sidebar v2 用。
    func allRecords() -> [SessionRecord] {
        repository.findAll()
    }
}

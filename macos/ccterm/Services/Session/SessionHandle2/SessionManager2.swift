import Foundation
import Observation

/// `SessionHandle2` 的注册表（v2 栈）。当前只承担「只读浏览历史会话」所需的最小职责：
/// 按 `sessionId` 懒创建并缓存 `SessionHandle2`。不做 launch / stop / archive / pin，
/// 这些仍在老 `SessionService` 上；v2 会在后续步骤逐步接管。
///
/// 持有独立的 `SessionRepository` 实例:生产为 `CoreDataSessionRepository`(与老栈
/// 共享 `CoreDataStack.shared`),UI test 为 `InMemorySessionRepository`(DEBUG only)。
@Observable
@MainActor
final class SessionManager2 {

    @ObservationIgnored private let repository: any SessionRepository
    @ObservationIgnored private var handles: [String: SessionHandle2] = [:]

    /// 未归档的会话记录，按 `lastActiveAt` 降序。Sidebar v2 直接观察此数组渲染。
    /// 由 `refreshRecords()` 主动刷新；初始化时填充一次。
    private(set) var records: [SessionRecord] = []

    /// 最近一次任何 handle 的 CLI 启动失败信息。RootView2 绑 `.alert` 观察此
    /// 字段:非 nil 即弹,确认后调 `clearLaunchFailure()` 复位。每条新失败
    /// 直接覆盖旧值——并发多失败时只保留最新,不堆栈(无 use case 需要全量)。
    private(set) var lastLaunchFailure: LaunchFailure?

    struct LaunchFailure: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let message: String
    }

    init(repository: any SessionRepository = CoreDataSessionRepository()) {
        self.repository = repository
        self.records = repository.findAll()
    }

    func clearLaunchFailure() {
        lastLaunchFailure = nil
    }

    /// 按 `sessionId` 获取 `SessionHandle2`。DB 无记录 → nil。
    /// 首次调用创建并缓存；后续返回同一实例（identity stable）。
    /// 只读浏览用，不启动子进程。
    func session(_ sessionId: String) -> SessionHandle2? {
        if let handle = handles[sessionId] { return handle }
        guard repository.find(sessionId) != nil else { return nil }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        wireLaunchFailure(handle)
        handles[sessionId] = handle
        return handle
    }

    /// 为 NewSession draft 准备 handle。DB 必须**无**对应记录（identity 由 UI 新生成的 UUID 给出）。
    /// 与 `session(_:)` 的区别：不读 repository，纯 in-memory 构造；后续 `activate()` /
    /// `send(_:)` 触发 `ensureStarted` 时走 fresh 路径写 DB。
    func prepareDraft(_ sessionId: String) -> SessionHandle2 {
        if let handle = handles[sessionId] { return handle }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        wireLaunchFailure(handle)
        handles[sessionId] = handle
        return handle
    }

    /// 把 handle 的 `onLaunchFailure` 接到本 manager 的 `lastLaunchFailure`。
    /// 每条新 handle 创建时调一次,后续 bootstrap 失败由 handle 同步触发,manager
    /// 写 observable 字段,RootView2 的 `.alert` 自动展示。
    private func wireLaunchFailure(_ handle: SessionHandle2) {
        let sid = handle.sessionId
        handle.onLaunchFailure = { [weak self] reason in
            // reason 是 handle 算好的原始描述,不再做本地化或字段重排。
            self?.lastLaunchFailure = LaunchFailure(
                sessionId: sid,
                message: reason
            )
        }
    }

    /// 重读 repository 全量记录并回写到 `records`。NewSession 启动后由调用方触发。
    func refreshRecords() {
        records = repository.findAll()
    }
}

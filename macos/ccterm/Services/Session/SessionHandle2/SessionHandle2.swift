import Foundation
import Observation
import AgentSDK

@Observable
@MainActor
class SessionHandle2 {

    enum Status {
        case notStarted
        case starting
        case idle
        case responding
        case interrupting
        case stopped
    }

    enum HistoryLoadState {
        case notLoaded
        case loading
        case loaded
        case failed(String)
    }

    // MARK: - Identity

    let sessionId: String
    internal let repository: SessionRepository

    // MARK: - Status

    internal(set) var status: Status = .notStarted
    internal(set) var historyLoadState: HistoryLoadState = .notLoaded

    /// 最近一次启动失败或进程异常退出的描述（含 exit code）。nil 表示"未发生"。
    /// 运行时由进程退出 handler 写入；hydrate 时从 `record.error` 还原。
    internal(set) var termination: String?

    // MARK: - Metadata

    internal(set) var title: String = ""
    internal(set) var originPath: String?
    internal(set) var worktreeBranch: String?
    internal(set) var isGeneratingBranch: Bool = false

    // MARK: - Configuration

    internal(set) var cwd: String?
    internal(set) var isWorktree: Bool = false
    internal(set) var model: String?
    internal(set) var effort: Effort?
    internal(set) var permissionMode: PermissionMode = .default
    internal(set) var additionalDirectories: [String] = []
    internal(set) var pluginDirectories: [String] = []

    // MARK: - Runtime

    internal(set) var messages: [MessageEntry] = []
    internal(set) var pendingPermissions: [PendingPermission] = []
    internal(set) var contextUsedTokens: Int = 0
    internal(set) var contextWindowTokens: Int = 0
    internal(set) var slashCommands: [SlashCommand] = []
    internal(set) var availableModels: [String] = []

    // MARK: - Presence

    internal(set) var isFocused: Bool = false
    internal(set) var hasUnread: Bool = false

    // MARK: - Init

    /// 创建 handle。**不新建独立 init 区分 fresh / resume**——sessionId 是 identity，
    /// 新旧 session 的差异由 handle 内部通过 `repository` 判断。
    ///
    /// 行为：
    /// - 同步从 `repository.find(sessionId)` 读取并 apply 持久化字段：`title` /
    ///   `cwd` / `isWorktree` / `originPath` / `worktreeBranch` / `termination` /
    ///   `model` / `effort` / `permissionMode` / `additionalDirectories` /
    ///   `pluginDirectories`（无记录时保持默认）。
    /// - **不加载历史消息**。`messages` 为空，`historyLoadState = .notLoaded`。
    ///   UI 进入 session 视图时显式调 `loadHistory()`，与 `start()` 解耦。
    /// - `status = .notStarted`。
    ///
    /// ## DB 写入时机（跨所有方法的总纲）
    ///
    /// - `init`：**不写 db**（纯内存构造，即使 sessionId 无记录也不创建孤儿）。
    /// - `.notStarted` 下的 `set*` 配置命令：只写字段（in-memory draft），**不写 db**。
    /// - `start()` 首次执行：把当前完整 configuration 一次性 `save` 到 db。
    /// - 已 start 后字段变化（CLI init 回包 / non-active 下重改）：didSet 触发
    ///   `repository.updateXxx` 增量更新。
    init(sessionId: String, repository: SessionRepository) {
        self.sessionId = sessionId
        self.repository = repository
        if let record = repository.find(sessionId) {
            apply(record)
        }
    }

    /// 把 `record` 的持久化字段映射到当前 handle。仅覆盖字段，不碰 status / messages。
    private func apply(_ record: SessionRecord) {
        title = record.title
        cwd = record.cwd
        isWorktree = record.isWorktree
        originPath = record.originPath
        worktreeBranch = record.worktreeBranch
        termination = record.error
        model = record.extra.model
        effort = record.extra.effort.flatMap(Effort.init(rawValue:))
        if let raw = record.extra.permissionMode,
           let mapped = PermissionMode(rawValue: raw) {
            permissionMode = mapped
        }
        additionalDirectories = record.extra.addDirs ?? []
        pluginDirectories = record.extra.pluginDirs ?? []
    }

    // MARK: - Lifecycle commands

    /// 启动 CLI 子进程。**不触发 loadHistory**（两者正交）。
    ///
    /// - `.notStarted` / `.stopped`：组装 `SessionConfiguration`（基于当前字段 +
    ///   app-level 启动参数），CLI launch 时若 `repository` 有历史记录则走 resume，否则 fresh。
    ///   `status` → `.starting` →（SDK ready）`.idle` 或（SDK 失败）`.stopped` + `termination` 写入。
    /// - 其他 status：no-op。
    ///
    /// 调用方（SessionService）不感知 fresh / resume 区别。
    func start() { fatalError() }

    /// 后台加载历史消息到 `messages`。幂等，按 `historyLoadState` 分派。
    ///
    /// - `.notLoaded`：`historyLoadState` → `.loading`，dispatch 后台 queue 读 JSONL 并解析；
    ///   完成后在主线程 append 到 `messages`，`historyLoadState` → `.loaded`。
    ///   解析失败 → `.failed(reason)`。
    /// - `.loading`：no-op（防重复调用）。
    /// - `.loaded`：no-op。
    /// - `.failed`：重试——切回 `.notLoaded` 并重新触发加载。
    ///
    /// 方法本身不阻塞调用线程；UI 通过观察 `historyLoadState` 展示 spinner / 错误。
    /// 与 `start()` 独立——stopped / notStarted session 也能查看历史。
    func loadHistory() { fatalError() }

    /// 手动停止 CLI 子进程。
    ///
    /// - active 状态（`.starting` / `.idle` / `.responding` / `.interrupting`）：
    ///   断开 SDK；`status` → `.stopped`；`.inFlight` 的 MessageEntry 转
    ///   `.failed("session stopped")`；`.queued` **保留**（下次 `start()` 后自动 flush）。
    /// - non-active：no-op。
    func stop() { fatalError() }

    // MARK: - Messaging commands

    /// 唯一发送入口。使用方不需要判断 status。
    ///
    /// 行为：
    /// 1. 无条件 append 一条 user `MessageEntry`（delivery = `.queued`）到 `messages`。
    /// 2. 如果 `status == .idle`：立即 flush 到 CLI，delivery → `.inFlight`，`status` → `.responding`。
    /// 3. 其他 status（`.responding` / `.interrupting` / `.notStarted` / `.starting` / `.stopped`）：
    ///    消息保留在 `.queued`；status 进入 `.idle` 时自动 flush。
    func send(_ message: SessionMessage) { fatalError() }

    /// 中断当前模型响应。
    ///
    /// - `.responding`：`status` → `.interrupting`；SDK ack 后 → `.idle`（并自动 flush queue）。
    /// - 其他 status：no-op。
    func interrupt() { fatalError() }

    /// 取消一条尚未发出或已失败的消息。
    ///
    /// - 目标 entry 的 delivery 为 `.queued` / `.failed`：从 `messages` 数组移除。
    /// - delivery 为 `.inFlight` / `.delivered`：no-op（已发出的不可取消，已完成的无必要）。
    /// - id 不存在或不是 user entry：no-op。
    func cancelMessage(id: UUID) { fatalError() }

    // MARK: - Configuration commands

    /// 变更 model。
    ///
    /// - `.notStarted` / `.stopped`（non-active）：**本地写入** `model` 字段，下次 `start()` 作为启动参数。
    /// - attached（`.idle` / `.responding` / `.interrupting`）：**发 RPC** 请求 CLI 切换；
    ///   `model` 字段不立即改，等 CLI init 消息回包覆盖。
    /// - `.starting`：待定（取决于 SDK 是否已 attach），保守按 attached 处理。
    func setModel(_ model: String?) { fatalError() }

    /// 变更推理力度。路由规则同 `setModel`。
    func setEffort(_ effort: Effort?) { fatalError() }

    /// 变更权限模式。路由规则同 `setModel`。
    func setPermissionMode(_ mode: PermissionMode) { fatalError() }

    /// 变更工作目录。
    ///
    /// - non-active（`.notStarted` / `.stopped`）：本地写入 `cwd`。
    /// - active：no-op（CLI 运行时不支持改 cwd；需先 `stop()`）。
    func setCwd(_ cwd: String) { fatalError() }

    /// 变更 worktree 开关。路由规则同 `setCwd`（运行时不可改）。
    func setWorktree(_ isWorktree: Bool) { fatalError() }

    /// 变更额外工作目录列表。路由规则同 `setCwd`（目前 AgentSDK 无运行时 RPC）。
    /// UI 层加/删单项用 read-modify-write：
    /// `handle.setAdditionalDirectories(handle.additionalDirectories + [path])`。
    func setAdditionalDirectories(_ dirs: [String]) { fatalError() }

    /// 变更插件目录列表。路由规则同 `setAdditionalDirectories`。
    func setPluginDirectories(_ dirs: [String]) { fatalError() }

    // MARK: - Permission

    /// 回应一条 pending permission。
    ///
    /// - 在 `pendingPermissions` 中找到对应 id：调用其 respond 闭包（自动回调 CLI 并从数组移除）。
    /// - id 不存在：no-op。
    func respond(to permissionId: String, decision: PermissionDecision) { fatalError() }

    // MARK: - Presence

    /// UI 写入"本 session 是否正被用户查看"。handle 不自改此字段。
    ///
    /// - `setFocused(true)`：立即清 `hasUnread = false`。
    /// - `setFocused(false)`：仅改 `isFocused`，不动 `hasUnread`。
    ///
    /// 调用时机（UI 层职责）：
    /// - `ChatRouter.activateSession` 切换：旧 handle 写 false、新 handle 写 true。
    /// - `AppState` 观察 NSWindow 失焦 / 重获焦点：对当前展示的 handle 写对应值。
    func setFocused(_ focused: Bool) { fatalError() }
}

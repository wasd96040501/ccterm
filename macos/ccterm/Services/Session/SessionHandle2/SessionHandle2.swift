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
    /// worktree 场景下的 branch 名。fresh + isWorktree 在 `ensureStarted()` 成功完成那刻
    /// 置为初始随机名（`<adj>-<sci>-<hex6>`），后续不再变更。非 worktree 会话为 nil。
    internal(set) var worktreeBranch: String?
    /// true 表示正在异步生成 title。UI 据此显示 shimmer/loading。
    /// 由 `generateTitle(from:)` 触发，`Prompt.runTitleAndBranch` 完成后复位。
    internal(set) var isGeneratingTitle: Bool = false

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

    // MARK: - Internal runtime

    /// 已绑定的 AgentSDK 子进程。bootstrap 中 `session.start()` 成功后赋值，
    /// 进程退出/stop 时清零。
    internal var agentSession: AgentSDK.Session?

    /// stderr 累积缓冲。进程退出时写入 `termination`。不持久化。
    @ObservationIgnored internal var stderrBuffer: String = ""

    /// 测试专用 hook：置 true 时 `ensureStarted()` 完成同步部分后立刻返回，不起 bootstrap Task，
    /// 也不动 CLI。用于纯 DB/状态断言。生产代码不得设置。
    @ObservationIgnored internal var skipBootstrapForTesting: Bool = false

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
    ///   UI 进入 session 视图时显式调 `loadHistory()`，与 `activate()` 解耦。
    /// - `status = .notStarted`。
    ///
    /// ## DB 写入时机（跨所有方法的总纲）
    ///
    /// - `init`：**不写 db**（纯内存构造，即使 sessionId 无记录也不创建孤儿）。
    /// - `.notStarted` 下的 `set*` 配置命令：只写字段（in-memory draft），**不写 db**。
    /// - 首次 `ensureStarted()`（由 `activate()` 或 `send(_:)` 触发）：把当前完整
    ///   configuration 一次性 `save` 到 db。
    /// - 已 start 后字段变化（CLI init 回包 / non-active 下重改）：didSet 触发
    ///   `repository.updateXxx` 增量更新。
    ///
    /// ## Setter 可调性矩阵
    ///
    /// | setter | attached 下 | 暴露的 canSet* |
    /// |---|---|---|
    /// | `setModel` / `setEffort` / `setPermissionMode` | 本地 + db + RPC | —（永远可调） |
    /// | `setAdditionalDirectories` | 本地 + db + applyFlagSettings RPC | —（永远可调） |
    /// | `setCwd` / `setWorktree` | no-op（CLI 运行时不支持） | `canSetCwd` / `canSetWorktree` |
    /// | `setPluginDirectories` | no-op（`--plugin-dir` 是启动参数） | `canSetPluginDirectories` |
    /// | `setFocused` | 本地（不碰 CLI） | —（永远可调） |
    /// | `respond(to:decision:)` | 本地（命中 pending 才生效） | — |
    init(sessionId: String, repository: SessionRepository) {
        self.sessionId = sessionId
        self.repository = repository
        if let record = repository.find(sessionId) {
            apply(record)
        }
    }

    /// @MainActor class deinit 否则会走 `swift_task_deinitOnExecutorImpl`，命中 macOS 26 SDK 的
    /// libswift_Concurrency bug（`TaskLocal::StopLookupScope` 析构时 free 未 malloc 的指针 → abort）。
    /// nonisolated deinit 跳过 executor-hop 路径规避该 bug。
    nonisolated deinit { }

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

    // `activate()` / `stop()` / `send(_:)` 实现与文档均在 `SessionHandle2+Start.swift`。

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
    /// 与 `activate()` 独立——stopped / notStarted session 也能查看历史。
    // impl in SessionHandle2+History.swift

    // MARK: - Messaging commands

    /// 中断当前模型响应。
    ///
    /// - `.responding`：`status` → `.interrupting`；SDK ack 后 → `.idle`。
    /// - 其他 status：no-op。
    // impl in SessionHandle2+Messaging.swift

    /// 取消一条尚未发出或已失败的消息。
    ///
    /// - 目标 entry 的 delivery 为 `.queued` / `.failed`：从 `messages` 数组移除。
    /// - delivery 为 `.confirmed`：no-op（CLI 已在处理，本地移除也无法让 CLI 停下）。
    /// - id 不存在或不是 user entry：no-op。
    // impl in SessionHandle2+Messaging.swift

    // MARK: - Configuration commands

    /// 变更 model。**乐观写入**语义：
    ///
    /// - `.notStarted` / `.stopped`（non-active）：仅改内存，下次 `ensureStarted` 作为启动参数。
    /// - attached（`.idle` / `.responding` / `.interrupting` / `.starting`）：
    ///   1. **立刻改内存**（UI 即时反馈，避免 RPC 往返的 100-300ms 停顿）
    ///   2. 并发发 RPC 通知 CLI 切换
    ///   3. CLI 后续 init/config 消息回包是 **authoritative**，若值与本地猜测不一致，
    ///      回包直接覆盖内存（不做 rollback，回包即真相）
    // impl in SessionHandle2+Configuration.swift

    /// 变更推理力度。路由规则同 `setModel`（乐观写入 + RPC + 回包覆盖）。
    // impl in SessionHandle2+Configuration.swift

    /// 变更权限模式。路由规则同 `setModel`（乐观写入 + RPC + 回包覆盖）。
    // impl in SessionHandle2+Configuration.swift

    /// 变更工作目录。
    ///
    /// - non-active（`.notStarted` / `.stopped`）：本地写入 `cwd`。
    /// - active：no-op（CLI 运行时不支持改 cwd；需先 `stop()`）。
    // impl in SessionHandle2+Configuration.swift

    /// 变更 worktree 开关。路由规则同 `setCwd`（运行时不可改）。
    // impl in SessionHandle2+Configuration.swift

    /// 变更额外工作目录列表。**运行时可改**——attached 下走
    /// `applyFlagSettings.permissions.additionalDirectories`。
    /// UI 层加/删单项用 read-modify-write：
    /// `handle.setAdditionalDirectories(handle.additionalDirectories + [path])`。
    // impl in SessionHandle2+Configuration.swift

    /// 变更插件目录列表。路由规则同 `setCwd`（`--plugin-dir` 是 CLI 启动参数，
    /// 运行时无 RPC）。UI 用 `canSetPluginDirectories` 禁用入口。
    // impl in SessionHandle2+Configuration.swift

    // MARK: - Permission

    /// 回应一条 pending permission。
    ///
    /// - 在 `pendingPermissions` 中找到对应 id：调用其 respond 闭包（自动回调 CLI 并从数组移除）。
    /// - id 不存在：no-op。
    // impl in SessionHandle2+Configuration.swift

    // MARK: - Presence

    /// UI 写入"本 session 是否正被用户查看"。handle 不自改此字段。
    ///
    /// - `setFocused(true)`：立即清 `hasUnread = false`。
    /// - `setFocused(false)`：仅改 `isFocused`，不动 `hasUnread`。
    ///
    /// 调用时机（UI 层职责）：
    /// - `ChatRouter.activateSession` 切换：旧 handle 写 false、新 handle 写 true。
    /// - `AppState` 观察 NSWindow 失焦 / 重获焦点：对当前展示的 handle 写对应值。
    // impl in SessionHandle2+Configuration.swift
}

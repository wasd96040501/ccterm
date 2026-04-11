import Foundation
import AgentSDK

// MARK: - SessionConfig

/// 启动会话所需的配置。从调用侧传入，不持久化。
struct SessionConfig {
    /// 用户选的原始目录。展示用，worktree 会话也保留原始仓库路径。
    let originPath: String
    /// 是否创建 worktree。true 时基于 originPath 创建 worktree，实际 cwd 从 sessionInit 返回。
    let isWorktree: Bool
    /// worktree 创建时基于的分支。nil 表示使用当前分支。
    let worktreeBaseBranch: String?
    /// MCP 插件目录。
    let pluginDirs: [String]?
    /// 额外挂载的目录（多目录模式）。
    let additionalDirs: [String]?
    /// 初始权限模式。
    let permissionMode: PermissionMode
    /// 初始模型。nil 表示使用默认模型。
    let model: String?
    /// 初始 effort。nil 表示使用默认 effort。
    let effort: AgentSDK.Effort?
    let isTempDir: Bool
    /// LLM 生成的 worktree 分支名（如 "feat/user-auth-login"）。nil 时 fallback 随机。
    var worktreeBranchName: String?

    init(originPath: String, isWorktree: Bool, worktreeBaseBranch: String? = nil, pluginDirs: [String]?, additionalDirs: [String]?, permissionMode: PermissionMode, model: String? = nil, effort: AgentSDK.Effort? = nil, isTempDir: Bool = false) {
        self.originPath = originPath
        self.isWorktree = isWorktree
        self.worktreeBaseBranch = worktreeBaseBranch
        self.pluginDirs = pluginDirs
        self.additionalDirs = additionalDirs
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
        self.isTempDir = isTempDir
    }
}

// MARK: - SessionStatus

/// 会话的持久化生命周期状态（存储在 CDSession.status 中）。
/// 与 SessionHandle.Status（运行时内存状态）互补，不要混淆。
enum SessionStatus: String {
    /// DB 已建，CLI 从未成功初始化（cwd 未知）。
    case pending
    /// CLI 至少成功初始化过一次，有完整元数据。
    case created
    /// 软删除（归档）。
    case archived
}

// MARK: - SessionService

/// SessionHandle 的工厂、注册表与子进程生命周期管理。
///
/// 职责：
/// - 创建/缓存 SessionHandle 实例（工厂 + 注册表）
/// - 管理 AgentSDK 子进程的启动/停止（生命周期）
/// - 封装 SessionRepository，外层不感知持久化细节
///
/// 不做的事：
/// - 不持有可观察状态（状态在 SessionHandle 上）
/// - 不暴露 SessionRepository 或 AgentSDK 类型给外部
/// - 不处理 AgentSDK 回调（由 SessionHandle.attach 自行设置）
///
/// 关系：SessionService 1 --创建/持有--* SessionHandle
///       SessionService 1 --内部持有--> 1 SessionRepository（private）
///
/// 调用场景：
///
/// ```swift
/// // 1. 浏览历史会话（只读，不启动子进程）
/// let handle = service.session(sessionId)   // status == .inactive，消息懒加载
///
/// // 2. 新建会话
/// let handle = try await service.start(config: config)  // 生成 UUID + 启动子进程
/// handle.send(.text("hello"))
///
/// // 3. 从历史恢复（启动子进程）
/// // start() 返回的 handle 与 session() 返回的是同一个实例（identity stable）
/// // 已持有 handle 时可以不接返回值，handle 的 status 会自动从 .inactive → .idle
/// try await service.start(sessionId: id, config: config)
/// handle.send(.text("继续"))
/// ```
///
/// 一个 app 一个实例。
@Observable
class SessionService {

    /// Repository 对外不可见，持久化逻辑封装在 SessionService 内部。
    @ObservationIgnored private let repository: SessionRepository

    /// JSONL 导出目录
    private static let exportDirectory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/ccterm/export")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Generates a worktree folder name: `<name>/<project-name>`.
    /// If `semanticName` is provided (e.g. "user-auth-login"), uses it as folder name with collision fallback.
    /// Otherwise falls back to random `<4-hex>`.
    private static func generateWorktreeName(for path: String, semanticName: String?) -> String {
        let projectName = URL(fileURLWithPath: path).lastPathComponent
        let baseName = semanticName ?? String(format: "%04x", UInt16.random(in: 0...0xFFFF))
        let worktreesBase = (path as NSString).appendingPathComponent(".claude/worktrees")

        // Check collision and append short hex suffix if needed
        let candidate = (worktreesBase as NSString).appendingPathComponent("\(baseName)/\(projectName)")
        if semanticName != nil, FileManager.default.fileExists(atPath: candidate) {
            let suffix = String(format: "%02x", UInt8.random(in: 0...0xFF))
            return "\(baseName)-\(suffix)/\(projectName)"
        }
        return "\(baseName)/\(projectName)"
    }

    /// Uses LLM (via AgentSDK Prompt API) to generate a semantic branch name from a task description.
    /// Returns a branch name like "feat/user-auth-login", or nil on failure.
    static func generateBranchName(description: String) async -> String? {
        // Use a temp directory to avoid loading project CLAUDE.md (saves tokens)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-prompt-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = PromptConfiguration(
            workingDirectory: tmpDir,
            model: "haiku",
            systemPrompt: "Git branch name generator. Rules: prefix with feat/, fix/, refactor/, or chore/. Then 2-4 kebab-case words. Reply with ONLY the branch name. No explanation, no quotes, no markdown.",
            tools: [],
            customCommand: UserDefaults.standard.string(forKey: "customCLICommand"),
            disableSlashCommands: true,
            effort: "low"
        )

        let truncatedDesc = String(description.prefix(80))
        NSLog("[SessionService] generateBranchName start — input: \"%@\"", truncatedDesc)
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await Prompt.run(
                message: "Generate a branch name for: \(description)",
                configuration: config
            )
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let usage = result.raw["usage"] as? [String: Any]
            let inputTokens = usage?["input_tokens"] as? Int ?? 0
            let outputTokens = usage?["output_tokens"] as? Int ?? 0
            let costUsd = result.totalCostUsd ?? 0

            let branch = sanitizeBranchName(result.result)
            if let branch {
                NSLog("[SessionService] generateBranchName done — branch: \"%@\", elapsed: %dms, tokens: %d in / %d out, cost: $%.6f",
                      branch, elapsed, inputTokens, outputTokens, costUsd)
            } else {
                NSLog("[SessionService] generateBranchName failed — invalid after sanitize, elapsed: %dms, raw: \"%@\"",
                      elapsed, String(result.result.prefix(200)))
            }
            return branch
        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            NSLog("[SessionService] generateBranchName failed — elapsed: %dms, error: %@", elapsed, "\(error)")
        }
        return nil
    }

    /// Sanitizes LLM output into a valid git branch name, or returns nil if unusable.
    private static func sanitizeBranchName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown wrapping: backticks, bold markers
        name = name.replacingOccurrences(of: #"^[`*]+|[`*]+$"#, with: "", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace git-illegal characters: space ~ ^ : ? * [ \ control chars
        name = name.replacingOccurrences(of: #"[\s~^:?*\[\]\\{}\x00-\x1f\x7f]+"#, with: "-", options: .regularExpression)
        // Replace .. (git disallows consecutive dots)
        name = name.replacingOccurrences(of: "..", with: "-")
        // Collapse consecutive dashes
        name = name.replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
        // Trim leading/trailing - and /
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        // Must contain a prefix like feat/
        guard name.contains("/"), !name.isEmpty else { return nil }
        return name
    }

    /// Creates a worktree directory at `.claude/worktrees/<name>/<project>` under the given repo path.
    /// If `branchName` is provided (e.g. "feat/user-auth-login"), uses it as branch and derives folder name.
    /// Falls back to random `wt-<hex>` branch on collision or when `branchName` is nil.
    /// Returns the worktree directory path on success, or `nil` on failure.
    private static func createWorktreeDirectory(repoPath: String, baseBranch: String?, branchName: String?) -> String? {
        // Derive folder name from branch: "feat/user-auth-login" → "user-auth-login"
        // Sanitize: replace filesystem-unsafe characters (/, \, :, spaces, etc.) with "-"
        let folderName = branchName.flatMap { branch -> String? in
            guard let body = branch.split(separator: "/", maxSplits: 1).last.map(String.init) else { return nil }
            let sanitized = body.replacingOccurrences(
                of: #"[/\\:\s\x00-\x1f*?"<>|.]+"#,
                with: "-",
                options: .regularExpression
            ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return sanitized.isEmpty ? nil : sanitized
        }
        let name = generateWorktreeName(for: repoPath, semanticName: folderName)
        let worktreesBase = (repoPath as NSString).appendingPathComponent(".claude/worktrees")
        let worktreePath = (worktreesBase as NSString).appendingPathComponent(name)
        let parentDir = (worktreePath as NSString).deletingLastPathComponent

        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let resolvedBase = baseBranch ?? GitUtils.currentBranch(at: repoPath) ?? "HEAD"
        let resolvedBranch = branchName ?? "wt-\(String(format: "%04x", UInt16.random(in: 0...0xFFFF)))"

        // Try with the resolved branch name; on collision (branch already exists), retry with hex suffix
        if GitUtils.createWorktree(repoPath: repoPath, worktreePath: worktreePath, branch: resolvedBranch, baseBranch: resolvedBase) {
            copyLocalSettings(from: repoPath, to: worktreePath)
            return worktreePath
        }

        // Branch name collision: retry with suffix
        if branchName != nil {
            let suffix = String(format: "%02x", UInt8.random(in: 0...0xFF))
            let fallbackBranch = "\(resolvedBranch)-\(suffix)"
            let fallbackName = generateWorktreeName(for: repoPath, semanticName: folderName.map { "\($0)-\(suffix)" })
            let fallbackPath = (worktreesBase as NSString).appendingPathComponent(fallbackName)
            let fallbackParent = (fallbackPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: fallbackParent, withIntermediateDirectories: true)

            if GitUtils.createWorktree(repoPath: repoPath, worktreePath: fallbackPath, branch: fallbackBranch, baseBranch: resolvedBase) {
                copyLocalSettings(from: repoPath, to: fallbackPath)
                return fallbackPath
            }
        }

        return nil
    }

    /// Copies `.claude/settings.local.json` from source repo to worktree if it exists.
    private static func copyLocalSettings(from repoPath: String, to worktreePath: String) {
        let source = (repoPath as NSString).appendingPathComponent(".claude/settings.local.json")
        guard FileManager.default.fileExists(atPath: source) else { return }
        let destDir = (worktreePath as NSString).appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let dest = (destDir as NSString).appendingPathComponent("settings.local.json")
        try? FileManager.default.copyItem(atPath: source, toPath: dest)
    }

    /// SessionHandle 缓存。key = sessionId，identity stable。
    private var handles: [String: SessionHandle] = [:]

    /// 注入的 bridge 引用。创建 handle 时自动绑定。
    @ObservationIgnored private var bridge: WebViewBridge?

    init() {
        self.repository = SessionRepository()
    }

    // MARK: - Bridge Management

    /// 注入 bridge 引用。AppState 初始化时调用一次。
    /// 之后所有创建的 handle 自动持有此 bridge。
    func setBridge(_ bridge: WebViewBridge) {
        self.bridge = bridge
        // 更新已有 handle
        for (_, handle) in handles {
            handle.bridge = bridge
        }
    }

    /// 移除 handle 并解绑 bridge。归档/删除 session 时调用。
    func removeHandle(_ sessionId: String) {
        if let handle = handles[sessionId] {
            handle.bridge = nil
        }
        handles.removeValue(forKey: sessionId)
    }

    // MARK: - Lifecycle

    /// 同步创建新 session 的 record 和 handle（不启动子进程）。
    /// handle.status 设置为 .starting，SidebarVM 立即感知。
    /// 后续调用 start(sessionId:config:) 启动子进程。
    func createNewSession(sessionId: String, config: SessionConfig, title: String) -> SessionHandle {
        let now = Date()
        let newSession = SessionRecord(
            id: UUID(),
            sessionId: sessionId,
            title: title,
            isWorktree: config.isWorktree,
            originPath: config.originPath,
            createdAt: now,
            lastActiveAt: now,
            status: .pending,
            extra: SessionExtra(
                pluginDirs: config.pluginDirs,
                permissionMode: config.permissionMode.rawValue,
                addDirs: config.additionalDirs,
                model: config.model,
                effort: config.effort?.rawValue
            ),
            isTempDir: config.isTempDir
        )
        repository.save(newSession)
        let handle = getOrCreateHandle(sessionId)
        handle.isWorktree = config.isWorktree
        handle.permissionMode = config.permissionMode
        handle.status = .starting
        handle.titleSet = true
        return handle
    }

    /// 启动会话的 AgentSDK 子进程并返回 SessionHandle。
    ///
    /// - sessionId == nil：新建会话。生成 UUID，创建最小 Session 实体（status = .pending），写入 DB。
    /// - sessionId != nil：恢复已有会话（或启动 createNewSession 预创建的 handle）。
    ///
    /// 内部流程：
    ///   1. sessionId == nil → 生成 UUID，创建最小 Session（status=.pending），repository.save()
    ///   2. 创建 AgentSDK.Session（配置来自 SessionConfig）
    ///   3. handle.attach(agentSession) — 绑定回调，handle.status → .starting
    ///   4. try agentSession.start() — 失败则写 error，status 不变，throw
    ///   5. await sessionInit 到达 — 写回 cwd，status → .created，handle.status → .idle
    ///   6. return handle
    ///
    /// async：等待 sessionInit 到达后返回。
    /// throws：子进程启动失败或 sessionInit 超时。
    @discardableResult
    func start(sessionId: String? = nil, config: SessionConfig) async throws -> SessionHandle {
        let resolvedId: String
        let isResume: Bool

        if let existingId = sessionId {
            resolvedId = existingId
            // 已有运行中子进程，直接返回
            if let handle = handles[resolvedId], handle.agentSession != nil {
                return handle
            }
            // 区分预创建新 session（record.status == .pending）和恢复已停止 session
            if let record = repository.find(resolvedId), record.status == .pending {
                isResume = false
            } else {
                isResume = true
            }
        } else {
            resolvedId = UUID().uuidString
            isResume = false
            // 新建最小 SessionRecord（status = .pending，cwd/title 待 sessionInit 后填充）
            let now = Date()
            let newSession = SessionRecord(
                id: UUID(),
                sessionId: resolvedId,
                isWorktree: config.isWorktree,
                originPath: config.originPath,
                createdAt: now,
                lastActiveAt: now,
                status: .pending,
                extra: SessionExtra(
                    pluginDirs: config.pluginDirs,
                    permissionMode: config.permissionMode.rawValue,
                    addDirs: config.additionalDirs,
                    model: config.model,
                    effort: config.effort?.rawValue
                ),
                isTempDir: config.isTempDir
            )
            repository.save(newSession)
        }

        // 获取或创建 handle
        let handle = getOrCreateHandle(resolvedId)
        NSLog("[SessionService] start() sessionId=%@ isResume=%@", resolvedId, isResume ? "true" : "false")

        // 创建 AgentSDK.Session
        // 读取用户自定义 CLI 命令前缀
        let customCLICommand = UserDefaults.standard.string(forKey: "customCLICommand")

        // cwd = 传给 CLI 的 workingDirectory
        // resume → record.cwd（上次实际工作目录）
        // 新建 + worktree → 创建 worktree 目录
        // 新建 → originPath
        var cwd = config.originPath
        if isResume, let recordCwd = repository.find(resolvedId)?.cwd {
            cwd = recordCwd
        } else if config.isWorktree, let wtPath = Self.createWorktreeDirectory(repoPath: config.originPath, baseBranch: config.worktreeBaseBranch, branchName: config.worktreeBranchName) {
            cwd = wtPath
        }
        NSLog("[SessionService] start() sessionId=%@ cwd=%@", resolvedId, cwd)

        let agentConfig = SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: cwd),
            model: config.model,
            permissionMode: config.permissionMode.toSDK(),
            sessionId: isResume ? nil : resolvedId,
            resume: isResume ? resolvedId : nil,
            worktree: nil,
            effort: config.effort,
            addDirs: config.additionalDirs ?? [],
            plugins: config.pluginDirs ?? [],
            customCommand: customCLICommand,
            allowDangerouslySkipPermissions: true,
            messageExportDirectory: Self.exportDirectory
        )
        let agentSession = AgentSDK.Session(configuration: agentConfig)
        agentSession.lastKnownSessionId = resolvedId

        // 设置初始状态
        handle.isWorktree = config.isWorktree
        handle.permissionMode = config.permissionMode

        // 绑定回调（在 start 之前设置，确保不丢消息），handle.status → .starting
        handle.attach(agentSession)

        // 启动子进程
        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            try await agentSession.start()
        } catch {
            NSLog("[SessionService] start() FAILED sessionId=%@ error=%@", resolvedId, "\(error)")
            handle.detach()
            repository.updateError(resolvedId, error: handle.lastExit?.stderr)
            throw error
        }
        let startElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        NSLog("[SessionService] agentSession.start() done sessionId=%@ elapsed=%.0fms", resolvedId, startElapsed)

        // initialize 获取 slash commands + 确认 CLI 就绪。
        // initialize 的 control_response 是 CLI 准备好的信号（system.init 要等第一条 user message 才发）。
        let initTime = CFAbsoluteTimeGetCurrent()
        let response: InitializeResponse? = await withCheckedContinuation { continuation in
            agentSession.initialize(promptSuggestions: true) { response in
                continuation.resume(returning: response)
            }
        }
        let initElapsed = (CFAbsoluteTimeGetCurrent() - initTime) * 1000
        NSLog("[SessionService] initialize() done sessionId=%@ elapsed=%.0fms commands=%d", resolvedId, initElapsed, response.flatMap { SlashCommand.from($0).count } ?? 0)

        if let response {
            let commands = SlashCommand.from(response)
            if !commands.isEmpty {
                handle.slashCommands = commands
            }
            if let models = response.models, !models.isEmpty {
                CLICapabilityStore.shared.update(from: models)
            }
        }

        handle.status = .idle

        // title 已设置过则标记跳过
        if let record = repository.find(resolvedId), record.title != "[unknown session]" {
            handle.titleSet = true
        }

        let totalElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        NSLog("[SessionService] start() completed sessionId=%@ totalElapsed=%.0fms → status=idle", resolvedId, totalElapsed)

        return handle
    }

    /// 停止会话的子进程。调用 handle.detach()。
    /// 无运行中子进程时调用无效果。
    func stop(_ sessionId: String) async {
        guard let handle = handles[sessionId], handle.status != .inactive else { return }
        NSLog("[SessionService] stop() sessionId=%@", sessionId)
        handle.detach()
    }

    /// 停止所有运行中的子进程。App 退出时调用。
    func stopAll() async {
        for sessionId in handles.keys {
            await stop(sessionId)
        }
    }

    // MARK: - Access

    /// 获取指定会话的 SessionHandle（如已缓存）。不创建新实例。
    func handle(for sessionId: String) -> SessionHandle? {
        handles[sessionId]
    }

    /// 所有已缓存的 SessionHandle（包含 inactive 和 active）。
    var allHandles: [String: SessionHandle] { handles }

    /// 获取已有会话的 SessionHandle（只读访问，不启动子进程）。
    ///
    /// sessionId 在 DB 中不存在时返回 nil。
    /// 首次调用时创建 SessionHandle 并缓存，后续返回同一实例（identity stable）。
    /// 返回的 handle 的 status == .inactive，消息在首次访问时从 JSONL 懒加载。
    /// 要启动子进程请用 start(sessionId:config:)。
    func session(_ sessionId: String) -> SessionHandle? {
        // 已缓存则直接返回
        if let handle = handles[sessionId] {
            return handle
        }
        // DB 中不存在则返回 nil
        guard repository.find(sessionId) != nil else { return nil }
        return getOrCreateHandle(sessionId)
    }

    /// 当前是否有子进程在运行。
    func isRunning(_ sessionId: String) -> Bool {
        guard let handle = handles[sessionId] else { return false }
        return handle.status != .inactive
    }

    // MARK: - Session Management

    /// 按 sessionId 查找单个会话记录。
    func find(_ sessionId: String) -> SessionRecord? {
        repository.find(sessionId)
    }

    /// 查找所有未归档的会话，按 lastActiveAt 降序。
    func findAll() -> [SessionRecord] {
        repository.findAll()
    }

    /// 查找所有已归档的会话。
    func findArchived() -> [SessionRecord] {
        repository.findArchived()
    }

    /// 归档会话（软删除）。status → .archived。
    /// worktree 会话：保存分支名 → git worktree remove → 清理空父目录。
    func archive(_ sessionId: String) {
        if let record = repository.find(sessionId),
           record.isWorktree,
           let cwd = record.cwd,
           let originPath = record.originPath {
            // 保存分支名，用于 unarchive 时重建
            let branch = GitUtils.currentBranch(at: cwd)
            if let branch {
                repository.updateWorktreeBranch(sessionId, branch: branch)
            }
            // 移除 worktree（不删除分支）
            GitUtils.removeWorktree(repoPath: originPath, worktreePath: cwd)
            // 清理空父目录（worktree 目录结构：.claude/worktrees/<name>/<project>）
            let parentDir = (cwd as NSString).deletingLastPathComponent
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir), contents.isEmpty {
                try? FileManager.default.removeItem(atPath: parentDir)
            }
            NSLog("[SessionService] archive() worktree removed sessionId=%@ branch=%@ cwd=%@",
                  sessionId, branch ?? "(nil)", cwd)
        }
        repository.archive(sessionId)
    }

    /// 取消归档。status → .created。
    /// worktree 会话：尝试用保存的分支名重建 worktree 目录。失败时保持 cwd 不变（resume 时会因目录不存在而报错）。
    func unarchive(_ sessionId: String) {
        if let record = repository.find(sessionId),
           record.isWorktree,
           let cwd = record.cwd,
           let originPath = record.originPath,
           let branch = record.worktreeBranch {
            let parentDir = (cwd as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            let success = GitUtils.addWorktreeForExistingBranch(
                repoPath: originPath,
                worktreePath: cwd,
                branch: branch
            )
            if success {
                Self.copyLocalSettings(from: originPath, to: cwd)
            }
            NSLog("[SessionService] unarchive() worktree restore sessionId=%@ branch=%@ success=%@",
                  sessionId, branch, success ? "true" : "false")
        }
        repository.unarchive(sessionId)
    }

    /// 置顶会话。
    func pinSession(_ sessionId: String) {
        repository.pinSession(sessionId: sessionId)
    }

    /// 取消置顶。
    func unpinSession(_ sessionId: String) {
        repository.unpinSession(sessionId: sessionId)
    }

    /// 该会话的 JSONL 文件路径。文件不存在时返回 nil。
    func jsonlFileURL(for sessionId: String) -> URL? {
        guard let url = getOrCreateHandle(sessionId).jsonlFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Private

    private func getOrCreateHandle(_ sessionId: String) -> SessionHandle {
        if let handle = handles[sessionId] {
            return handle
        }
        let handle = SessionHandle(sessionId: sessionId, repository: repository)
        handle.bridge = bridge  // 创建时绑定 bridge
        handles[sessionId] = handle
        return handle
    }

}

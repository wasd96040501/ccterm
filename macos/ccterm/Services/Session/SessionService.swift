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
/// let handle = service.provisionSession(sessionId: id, config: config, title: "...")
/// handle.status = .starting
/// try await service.launch(sessionId: id, config: config, taskDescription: text)
/// handle.send(.text("hello"))
///
/// // 3. 从历史恢复（启动子进程）
/// handle.status = .starting
/// try await service.relaunch(sessionId: id, config: config)
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
    /// Uses random `wt-<hex>` branch when `branchName` is nil.
    /// On branch name collision, retries with incrementing suffix (`-2`, `-3`, ...) up to 10 attempts.
    /// Throws on failure instead of silently falling back.
    static func createWorktreeDirectory(repoPath: String, baseBranch: String?, branchName: String?) throws -> String {
        // Validate: must be a git repository
        guard GitUtils.isGitRepository(at: repoPath) else {
            throw WorktreeCreationError.notGitRepository(path: repoPath)
        }

        // Resolve base branch: explicit > current branch > error (no silent HEAD fallback)
        let resolvedBase: String
        if let base = baseBranch {
            resolvedBase = base
        } else if let current = GitUtils.currentBranch(at: repoPath) {
            resolvedBase = current
        } else {
            throw WorktreeCreationError.detachedHead
        }

        // Derive folder name from branch: "feat/user-auth-login" → "user-auth-login"
        let folderName = branchName.flatMap { branch -> String? in
            guard let body = branch.split(separator: "/", maxSplits: 1).last.map(String.init) else { return nil }
            let sanitized = body.replacingOccurrences(
                of: #"[/\\:\s\x00-\x1f*?"<>|.]+"#,
                with: "-",
                options: .regularExpression
            ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return sanitized.isEmpty ? nil : sanitized
        }

        let worktreesBase = (repoPath as NSString).appendingPathComponent(".claude/worktrees")
        let resolvedBranch = branchName ?? "wt-\(String(format: "%04x", UInt16.random(in: 0...0xFFFF)))"

        // Try with incrementing suffix on branch collision: base, base-2, base-3, ...
        let maxAttempts = 10
        var lastError: GitUtils.WorktreeError?

        for attempt in 1...maxAttempts {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let candidateBranch = resolvedBranch + suffix
            let candidateFolder = folderName.map { $0 + suffix }
            let name = generateWorktreeName(for: repoPath, semanticName: candidateFolder)
            let worktreePath = (worktreesBase as NSString).appendingPathComponent(name)
            let parentDir = (worktreePath as NSString).deletingLastPathComponent

            do {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            } catch {
                throw WorktreeCreationError.directoryCreationFailed(path: parentDir, underlying: error.localizedDescription)
            }

            switch GitUtils.createWorktree(repoPath: repoPath, worktreePath: worktreePath, branch: candidateBranch, baseBranch: resolvedBase) {
            case .success:
                copyLocalSettings(from: repoPath, to: worktreePath)
                return worktreePath
            case .failure(let wtError):
                lastError = wtError
                if wtError.isBranchConflict {
                    // Clean up the failed worktree path if it was partially created
                    try? FileManager.default.removeItem(atPath: worktreePath)
                    continue
                }
                // Non-collision error: no point retrying
                throw WorktreeCreationError.gitError(stderr: wtError.stderr)
            }
        }

        // Exhausted all attempts — all were branch collisions
        throw WorktreeCreationError.branchCollisionExhausted(
            branch: resolvedBranch,
            attempts: maxAttempts,
            lastStderr: lastError?.stderr ?? ""
        )
    }

    enum WorktreeCreationError: Error, LocalizedError {
        case notGitRepository(path: String)
        case detachedHead
        case directoryCreationFailed(path: String, underlying: String)
        case gitError(stderr: String)
        case branchCollisionExhausted(branch: String, attempts: Int, lastStderr: String)

        var errorDescription: String? {
            switch self {
            case .notGitRepository(let path):
                return "Not a git repository: \(path)"
            case .detachedHead:
                return "Repository is in detached HEAD state. Please checkout a branch before creating a worktree."
            case .directoryCreationFailed(let path, let underlying):
                return "Failed to create worktree directory at \(path): \(underlying)"
            case .gitError(let stderr):
                return "Git worktree creation failed: \(stderr)"
            case .branchCollisionExhausted(let branch, let attempts, _):
                return "Branch \"\(branch)\" and \(attempts - 1) suffixed variants already exist. Please delete stale branches or use a different name."
            }
        }
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
    /// 调用方负责设置 handle.status = .starting。
    /// 后续调用 launch(sessionId:config:taskDescription:) 启动子进程。
    func provisionSession(sessionId: String, config: SessionConfig, title: String) -> SessionHandle {
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
        handle.titleSet = true
        return handle
    }

    /// 新会话启动。调用方须先 provisionSession 并设 handle.status = .starting。
    /// 重活（worktree 创建、config 构造）在后台线程执行，不阻塞主线程。
    func launch(sessionId: String, config: SessionConfig, taskDescription: String? = nil) async throws {
        let handle = getOrCreateHandle(sessionId)
        NSLog("[SessionService] launch() sessionId=%@", sessionId)

        // 主线程：解构 config 为值类型
        let originPath = config.originPath
        let isWorktree = config.isWorktree
        let baseBranch = config.worktreeBaseBranch
        let model = config.model
        let permissionMode = config.permissionMode.toSDK()
        let effort = config.effort
        let addDirs = config.additionalDirs ?? []
        let plugins = config.pluginDirs ?? []
        let exportDir = Self.exportDirectory

        // 后台线程：重活
        nonisolated(unsafe) let agentSession = try await Task.detached {
            var cwd = originPath
            if isWorktree {
                let branchName = await SessionService.generateBranchName(description: taskDescription ?? "")
                cwd = try SessionService.createWorktreeDirectory(
                    repoPath: originPath, baseBranch: baseBranch, branchName: branchName
                )
            }
            let customCLI = UserDefaults.standard.string(forKey: "customCLICommand")
            let agentConfig = SessionConfiguration(
                workingDirectory: URL(fileURLWithPath: cwd),
                model: model,
                permissionMode: permissionMode,
                sessionId: sessionId,
                resume: nil,
                worktree: nil,
                effort: effort,
                addDirs: addDirs,
                plugins: plugins,
                customCommand: customCLI,
                allowDangerouslySkipPermissions: true,
                messageExportDirectory: exportDir
            )
            let session = AgentSDK.Session(configuration: agentConfig)
            session.lastKnownSessionId = sessionId
            return session
        }.value

        handle.isWorktree = config.isWorktree
        handle.permissionMode = config.permissionMode
        try await bootstrap(handle: handle, agentSession: agentSession, sessionId: sessionId)
    }

    /// 恢复已停止会话。调用方须先设 handle.status = .starting。
    func relaunch(sessionId: String, config: SessionConfig) async throws {
        let handle = getOrCreateHandle(sessionId)
        NSLog("[SessionService] relaunch() sessionId=%@", sessionId)

        // 主线程：读历史 cwd（轻量 CoreData 查询）
        let historyCwd = repository.find(sessionId)?.cwd ?? config.originPath
        let model = config.model
        let permissionMode = config.permissionMode.toSDK()
        let effort = config.effort
        let addDirs = config.additionalDirs ?? []
        let plugins = config.pluginDirs ?? []
        let exportDir = Self.exportDirectory

        nonisolated(unsafe) let agentSession = try await Task.detached {
            let customCLI = UserDefaults.standard.string(forKey: "customCLICommand")
            let agentConfig = SessionConfiguration(
                workingDirectory: URL(fileURLWithPath: historyCwd),
                model: model,
                permissionMode: permissionMode,
                sessionId: nil,
                resume: sessionId,
                worktree: nil,
                effort: effort,
                addDirs: addDirs,
                plugins: plugins,
                customCommand: customCLI,
                allowDangerouslySkipPermissions: true,
                messageExportDirectory: exportDir
            )
            let session = AgentSDK.Session(configuration: agentConfig)
            session.lastKnownSessionId = sessionId
            return session
        }.value

        handle.isWorktree = config.isWorktree
        handle.permissionMode = config.permissionMode
        try await bootstrap(handle: handle, agentSession: agentSession, sessionId: sessionId)
    }

    /// 共享后半段：attach → start → initialize → idle。
    private func bootstrap(handle: SessionHandle, agentSession: AgentSDK.Session, sessionId: String) async throws {
        handle.attach(agentSession)

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            try await agentSession.start()
        } catch {
            NSLog("[SessionService] bootstrap() FAILED sessionId=%@ error=%@", sessionId, "\(error)")
            handle.detach()
            repository.updateError(sessionId, error: handle.lastExit?.stderr)
            throw error
        }
        let startElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        NSLog("[SessionService] agentSession.start() done sessionId=%@ elapsed=%.0fms", sessionId, startElapsed)

        let initTime = CFAbsoluteTimeGetCurrent()
        let response: InitializeResponse? = await withCheckedContinuation { continuation in
            agentSession.initialize(promptSuggestions: true) { response in
                continuation.resume(returning: response)
            }
        }
        let initElapsed = (CFAbsoluteTimeGetCurrent() - initTime) * 1000
        NSLog("[SessionService] initialize() done sessionId=%@ elapsed=%.0fms", sessionId, initElapsed)

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

        if let record = repository.find(sessionId), record.title != "[unknown session]" {
            handle.titleSet = true
        }

        let totalElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        NSLog("[SessionService] bootstrap completed sessionId=%@ totalElapsed=%.0fms", sessionId, totalElapsed)
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
    /// 要启动子进程请用 launch(sessionId:config:) 或 relaunch(sessionId:config:)。
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

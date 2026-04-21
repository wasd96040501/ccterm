import Foundation
import AgentSDK

// MARK: - Attached predicate

extension SessionHandle2 {

    /// 是否绑定了 CLI 子进程。`.starting` / `.idle` / `.responding` / `.interrupting` 视为 attached。
    var isAttached: Bool {
        switch status {
        case .starting, .idle, .responding, .interrupting: return true
        case .notStarted, .stopped: return false
        }
    }

    // MARK: - canSet* (observable, for UI binding)
    //
    // 只为「运行时受限」的 setter 暴露 canSet*；永远可调的 setter（model / effort /
    // permissionMode / additionalDirectories / focused）无 flag——UI 不需要禁用。

    /// `setCwd` 是否可调。CLI 运行时不支持改 cwd，attached 下拒。
    var canSetCwd: Bool { !isAttached }
    /// `setWorktree` 是否可调。运行时不可改。
    var canSetWorktree: Bool { !isAttached }
    /// `setPluginDirectories` 是否可调。`--plugin-dir` 是 CLI 启动参数，运行时无 RPC。
    var canSetPluginDirectories: Bool { !isAttached }

    /// 当前 sessionId 是否已在 repository 中持久化。用于决定 set* 是否写 db。
    /// 首次 `ensureStarted()` 前 fresh 态为 false；之后或 resume 均为 true。
    private var isPersisted: Bool { repository.find(sessionId) != nil }
}

// MARK: - Configuration: model / effort / permissionMode（乐观写入 + RPC）

extension SessionHandle2 {

    /// 变更 model。乐观写入：立刻改内存、持久化（若已有 record）、attached 下发 RPC。
    /// CLI init 回包为 authoritative，若不同会覆盖本地值。
    ///
    /// 不接受 nil——内部 storage 为 `String?` 仅为"未设置"占位，UI 场景无清空需求；
    /// 且 `SessionExtraUpdate` 以 nil 表示"不更新"，无法表达"清回 nil"。
    func setModel(_ model: String) {
        self.model = model
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(model: model))
        }
        if isAttached, !model.isEmpty {
            agentSession?.setModel(model)
        }
    }

    /// 变更推理力度。路由规则同 `setModel`。不接受 nil（理由同上）。
    func setEffort(_ effort: Effort) {
        self.effort = effort
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(effort: effort.rawValue))
        }
        if isAttached {
            agentSession?.setEffort(effort)
        }
    }

    /// 变更权限模式。路由规则同 `setModel`。
    func setPermissionMode(_ mode: PermissionMode) {
        self.permissionMode = mode
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(permissionMode: mode.rawValue))
        }
        if isAttached {
            agentSession?.setPermissionMode(mode.toSDK())
        }
    }
}

// MARK: - Configuration: cwd / worktree / dirs（仅 non-active）

extension SessionHandle2 {

    /// 变更工作目录。attached 下 no-op（CLI 运行时不支持改 cwd；需先 stop）。
    func setCwd(_ cwd: String) {
        guard !isAttached else {
            appLog(.info, "SessionHandle2", "setCwd ignored — attached \(sessionId)")
            return
        }
        self.cwd = cwd
        if isPersisted {
            repository.updateCwd(sessionId, cwd: cwd)
        }
    }

    /// 变更 worktree 开关。路由规则同 `setCwd`（运行时不可改）。
    func setWorktree(_ isWorktree: Bool) {
        guard !isAttached else {
            appLog(.info, "SessionHandle2", "setWorktree ignored — attached \(sessionId)")
            return
        }
        self.isWorktree = isWorktree
        if isPersisted {
            repository.updateIsWorktree(sessionId, isWorktree: isWorktree)
        }
    }

    /// 变更插件目录列表。`--plugin-dir` 是 CLI 启动参数，运行时无对应 RPC——attached
    /// 下 no-op（不写内存、不写 db），UI 直接 bind `canSetPluginDirectories` 禁用入口。
    func setPluginDirectories(_ dirs: [String]) {
        guard !isAttached else {
            appLog(.info, "SessionHandle2", "setPluginDirectories ignored — attached \(sessionId)")
            return
        }
        self.pluginDirectories = dirs
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(pluginDirs: dirs))
        }
    }
}

// MARK: - Configuration: additionalDirectories（运行时可改；attached 下走 RPC）

extension SessionHandle2 {

    /// 变更额外工作目录列表。运行时可改——走 `applyFlagSettings.permissions.additionalDirectories`。
    /// UI 层加/删单项用 read-modify-write：
    /// `handle.setAdditionalDirectories(handle.additionalDirectories + [path])`。
    func setAdditionalDirectories(_ dirs: [String]) {
        self.additionalDirectories = dirs
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(addDirs: dirs))
        }
        if isAttached {
            var perms = FlagSettings.Permissions()
            perms.additionalDirectories = dirs
            var settings = FlagSettings()
            settings.permissions = .set(perms)
            agentSession?.applyFlagSettings(settings)
        }
    }
}

// MARK: - Permission

extension SessionHandle2 {

    /// 回应一条 pending permission。命中则调 respond 闭包（闭包内部会自动从数组移除）；
    /// 未命中 no-op。
    func respond(to permissionId: String, decision: PermissionDecision) {
        guard let pending = pendingPermissions.first(where: { $0.id == permissionId }) else {
            appLog(.info, "SessionHandle2", "respond no-match id=\(permissionId) \(sessionId)")
            return
        }
        pending.respond(decision)
    }
}

// MARK: - Presence

extension SessionHandle2 {

    /// UI 写入"本 session 是否正被用户查看"。聚焦时清 `hasUnread`，失焦时不动。
    func setFocused(_ focused: Bool) {
        isFocused = focused
        if focused {
            hasUnread = false
        }
    }
}

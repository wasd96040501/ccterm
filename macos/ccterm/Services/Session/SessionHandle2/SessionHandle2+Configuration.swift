import AgentSDK
import Foundation

// MARK: - Attached predicate

extension SessionHandle2 {

    /// True when bound to a CLI subprocess. `.starting` / `.idle` /
    /// `.responding` / `.interrupting` count as attached.
    var isAttached: Bool {
        switch status {
        case .starting, .idle, .responding, .interrupting: return true
        case .notStarted, .stopped: return false
        }
    }

    // MARK: - canSet* (observable, for UI binding)
    //
    // Only setters constrained at runtime expose canSet*; always-callable
    // setters (model / effort / permissionMode / additionalDirectories /
    // focused) have no flag — the UI never needs to disable them.

    /// CLI does not support changing cwd at runtime; refused while attached.
    var canSetCwd: Bool { !isAttached }
    /// Worktree flag cannot change at runtime.
    var canSetWorktree: Bool { !isAttached }
    /// `--plugin-dir` is a CLI launch argument with no runtime RPC.
    var canSetPluginDirectories: Bool { !isAttached }

    /// Whether the current sessionId is already persisted. Used to decide
    /// whether `set*` writes the db. False before the first `ensureStarted()`
    /// in fresh mode, true thereafter and for resume.
    private var isPersisted: Bool { repository.find(sessionId) != nil }
}

// MARK: - Configuration: model / effort / permissionMode (optimistic write + RPC)

extension SessionHandle2 {

    /// Optimistic write: update memory immediately, persist (if a record
    /// exists), and send RPC when attached. The CLI's init reply is
    /// authoritative — a divergent value will overwrite the local one.
    ///
    /// Does not accept nil — the underlying `String?` storage is just an
    /// "unset" placeholder, no UI flow needs to clear it, and
    /// `SessionExtraUpdate` uses nil to mean "no update", so nil cannot
    /// express "clear back to nil".
    func setModel(_ model: String) {
        self.model = model
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(model: model))
        }
        if isAttached, !model.isEmpty {
            agentSession?.setModel(model)
        }
    }

    /// Same routing as `setModel`. Does not accept nil (same reason).
    func setEffort(_ effort: Effort) {
        self.effort = effort
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(effort: effort.rawValue))
        }
        if isAttached {
            agentSession?.setEffort(effort)
        }
    }

    /// Same routing as `setModel`.
    func setPermissionMode(_ mode: PermissionMode) {
        self.permissionMode = mode
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(permissionMode: mode.rawValue))
        }
        if isAttached {
            agentSession?.setPermissionMode(mode.toSDK())
        }
    }

    /// Toggle "fast mode" for the current session. Memory-only (the CLI
    /// flag is documented as not persisted across sessions), pushed to
    /// the CLI via `applyFlagSettings.fastMode` when attached. Compose
    /// mode writes are applied at the tail of `bootstrap` via
    /// `flushDeferredFastMode()` so the user's pre-launch toggle is
    /// honored on the first turn.
    func setFastMode(_ enabled: Bool) {
        fastModeEnabled = enabled
        if isAttached {
            agentSession?.setFastMode(enabled)
        }
    }

    /// Called by `bootstrap` once the CLI hits `.idle`. Replays the
    /// user's pre-start toggle (a no-op when off — the CLI's default is
    /// off, so we don't have to send an extra RPC to confirm it).
    internal func flushDeferredFastMode() {
        guard fastModeEnabled else { return }
        agentSession?.setFastMode(true)
    }
}

// MARK: - Configuration: cwd / worktree / dirs (non-active only)

extension SessionHandle2 {

    /// No-op while attached (CLI runtime can't change cwd; stop first).
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

    /// Same routing as `setCwd` (cannot change at runtime).
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

    /// Set the user-selected source directory. Persisted at `ensureStarted`'s
    /// fresh save (read by `SessionRecord.originPath`); also the base repo
    /// for worktree provisioning (read by `provisionWorktreeIfNeeded`). Used
    /// by `groupingFolderName` to bucket sidebar history. Non-active only.
    func setOriginPath(_ originPath: String?) {
        guard !isAttached else {
            appLog(.info, "SessionHandle2", "setOriginPath ignored — attached \(sessionId)")
            return
        }
        self.originPath = originPath
    }

    /// Set the source branch for worktree provisioning. Read by
    /// `Worktree.create(from:sourceBranch:)` at `ensureStarted` time; after
    /// the worktree is created, `ensureStarted` overwrites this field with
    /// the generated `<adj>-<sci>-<hex>` branch name. Non-active only.
    func setWorktreeBranch(_ branch: String?) {
        guard !isAttached else {
            appLog(.info, "SessionHandle2", "setWorktreeBranch ignored — attached \(sessionId)")
            return
        }
        self.worktreeBranch = branch
        if isPersisted {
            repository.updateWorktreeBranch(sessionId, branch: branch)
        }
    }

    /// `--plugin-dir` is a CLI launch argument with no runtime RPC — no-op
    /// while attached (no memory or db write). UI binds
    /// `canSetPluginDirectories` to disable the entry point.
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

// MARK: - Configuration: additionalDirectories (mutable at runtime via RPC)

extension SessionHandle2 {

    /// Mutable at runtime via
    /// `applyFlagSettings.permissions.additionalDirectories`. UI layer
    /// adds/removes single entries with read-modify-write:
    /// `handle.setAdditionalDirectories(handle.additionalDirectories + [path])`.
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

    /// Reply to a pending permission. Calls the respond closure on a hit
    /// (the closure removes the entry from the array); no-op otherwise.
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

    /// UI sets whether the session is currently being viewed. Focusing clears
    /// `hasUnread`; defocusing does not change it.
    func setFocused(_ focused: Bool) {
        isFocused = focused
        if focused {
            hasUnread = false
        }
    }
}

import AgentSDK
import Foundation

// MARK: - Attached predicate

extension SessionRuntime {

    /// True when bound to a CLI subprocess. `.starting` / `.idle` /
    /// `.responding` / `.interrupting` count as attached.
    var isAttached: Bool {
        switch status {
        case .starting, .idle, .responding, .interrupting: return true
        // `.provisioning` is pre-attach — the ssh/remote setup runs before any
        // CLI subprocess exists, so there is nothing to talk to yet.
        case .provisioning, .notStarted, .stopped: return false
        }
    }

    /// Whether the current sessionId is already persisted. Used to decide
    /// whether `set*` writes the db. False before the first `ensureStarted()`
    /// runs in fresh mode, true thereafter and for resume.
    fileprivate var isPersisted: Bool { repository.find(sessionId) != nil }
}

// MARK: - Configuration: model / effort / permissionMode (optimistic write + RPC)

extension SessionRuntime {

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
            cliClient?.setModel(model)
        }
    }

    /// Same routing as `setModel`. Does not accept nil (same reason).
    func setEffort(_ effort: Effort) {
        self.effort = effort
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(effort: effort.rawValue))
        }
        if isAttached {
            cliClient?.setEffort(effort)
        }
    }

    /// Same routing as `setModel`.
    func setPermissionMode(_ mode: PermissionMode) {
        self.permissionMode = mode
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(permissionMode: mode.rawValue))
        }
        if isAttached {
            cliClient?.setPermissionMode(mode.toSDK())
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
            cliClient?.setFastMode(enabled)
        }
    }

    /// Called by `bootstrap` once the CLI hits `.idle`. Replays the
    /// user's pre-start toggle (a no-op when off — the CLI's default is
    /// off, so we don't have to send an extra RPC to confirm it).
    internal func flushDeferredFastMode() {
        guard fastModeEnabled else { return }
        cliClient?.setFastMode(true)
    }
}

// MARK: - Configuration: additionalDirectories (mutable at runtime via RPC)

extension SessionRuntime {

    /// Mutable at runtime via
    /// `applyFlagSettings.permissions.additionalDirectories`. UI layer
    /// adds/removes single entries with read-modify-write:
    /// `runtime.setAdditionalDirectories(runtime.additionalDirectories + [path])`.
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
            cliClient?.applyFlagSettings(settings)
        }
    }
}

// MARK: - Permission

extension SessionRuntime {

    /// Reply to a pending permission. Calls the respond closure on a hit
    /// (the closure removes the entry from the array); no-op otherwise.
    func respond(to permissionId: String, decision: PermissionDecision) {
        guard let pending = pendingPermissions.first(where: { $0.id == permissionId }) else {
            appLog(.info, "SessionRuntime", "respond no-match id=\(permissionId) \(sessionId)")
            return
        }
        pending.respond(decision)
    }
}

// MARK: - Presence

extension SessionRuntime {

    /// UI sets whether the session is currently being viewed. Focusing clears
    /// `hasUnread`; defocusing does not change it.
    func setFocused(_ focused: Bool) {
        isFocused = focused
        if focused {
            hasUnread = false
        }
    }
}

import AgentSDK
import Foundation

// MARK: - Attached predicate

extension SessionRuntime {

    /// True when bound to a CLI subprocess. `.starting` / `.idle` /
    /// `.responding` / `.interrupting` count as attached.
    var isAttached: Bool {
        switch status {
        case .starting, .idle, .responding, .interrupting: return true
        case .notStarted, .stopped: return false
        }
    }

    /// Whether the current sessionId is already persisted. Used to decide
    /// whether `set*` writes the db. False before the first `ensureStarted()`
    /// runs in fresh mode, true thereafter and for resume.
    fileprivate var isPersisted: Bool { repository.find(sessionId) != nil }

    /// Sends a request to the attached CLI without waiting for it. A failure
    /// is only logged: the CLI's next `system.init` / `system.status` report
    /// is authoritative and pulls local state back in line.
    fileprivate func command(_ name: String, _ request: @escaping (any CLIClient) async throws -> Void) {
        guard let client = cliClient else { return }
        let sid = sessionId
        Task {
            do {
                try await request(client)
            } catch {
                appLog(.warning, "SessionRuntime", "\(name) failed \(sid): \(error)")
            }
        }
    }
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
            command("setModel") { try await $0.setModel(model) }
        }
    }

    /// Same routing as `setModel`. Does not accept nil (same reason).
    func setEffort(_ effort: Effort) {
        self.effort = effort
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(effort: effort.rawValue))
        }
        if isAttached {
            command("setEffort") { try await $0.applySettings(effort.settings) }
        }
    }

    /// Same routing as `setModel`.
    func setPermissionMode(_ mode: PermissionMode) {
        self.permissionMode = mode
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(permissionMode: mode.rawValue))
        }
        if isAttached {
            command("setPermissionMode") { try await $0.setPermissionMode(mode.toSDK()) }
        }
    }

    /// Toggle "fast mode" for the current session. Memory-only (the CLI
    /// flag is documented as not persisted across sessions), pushed to
    /// the CLI via `applySettings` (`fastMode`) when attached. Compose
    /// mode writes are applied at the tail of `bootstrap` via
    /// `flushDeferredFastMode()` so the user's pre-launch toggle is
    /// honored on the first turn.
    func setFastMode(_ enabled: Bool) {
        fastModeEnabled = enabled
        if isAttached {
            command("setFastMode") { try await $0.applySettings(Self.settings(.fastMode, enabled)) }
        }
    }

    /// Called by `bootstrap` once the CLI hits `.idle`. Replays the
    /// user's pre-start toggle (a no-op when off — the CLI's default is
    /// off, so we don't have to send an extra RPC to confirm it).
    internal func flushDeferredFastMode() {
        guard fastModeEnabled else { return }
        command("setFastMode") { try await $0.applySettings(Self.settings(.fastMode, true)) }
    }
}

// MARK: - Configuration: additionalDirectories (mutable at runtime via RPC)

extension SessionRuntime {

    /// Mutable at runtime via `applySettings` (the `permissions` setting,
    /// which this session only uses for its extra directories). UI layer
    /// adds/removes single entries with read-modify-write:
    /// `runtime.setAdditionalDirectories(runtime.additionalDirectories + [path])`.
    func setAdditionalDirectories(_ dirs: [String]) {
        self.additionalDirectories = dirs
        if isPersisted {
            repository.updateExtra(sessionId, with: SessionExtraUpdate(addDirs: dirs))
        }
        if isAttached {
            let settings = Self.settings(.permissions, PermissionSettings(additionalDirectories: dirs))
            command("setAdditionalDirectories") { try await $0.applySettings(settings) }
        }
    }
}

// MARK: - Permission

extension SessionRuntime {

    /// Answers a pending permission and removes its card; no-op for an id
    /// that is no longer pending.
    func respond(to permissionId: String, decision: PermissionDecision) {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == permissionId }) else {
            appLog(.info, "SessionRuntime", "respond no-match id=\(permissionId) \(sessionId)")
            return
        }
        pendingPermissions.remove(at: index).respond(decision)
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

extension SessionRuntime {
    /// Settings holding just `value` for `key`.
    fileprivate static func settings<Value>(_ key: SettingsKey<Value>, _ value: Value) -> AgentSDK.Settings {
        var settings = AgentSDK.Settings()
        settings[key] = value
        return settings
    }
}

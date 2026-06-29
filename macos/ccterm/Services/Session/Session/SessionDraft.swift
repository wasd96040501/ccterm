import AgentSDK
import Foundation
import Observation

/// A still-being-configured chat session that hasn't been sent yet.
///
/// `SessionDraft` carries the user's compose-card selections (cwd /
/// worktree / source branch / model / effort / permission mode / extra
/// dirs / plugin dirs / fast mode) before there is any CLI subprocess
/// or persisted record. It exists solely as the source value for the
/// promotion path: `Session.send(...)` constructs a `SessionRuntime`
/// via `SessionRuntime.fromDraft(_:cliClientFactory:initialInput:)`,
/// which copies the draft's `config` / `title` / presence verbatim and
/// kicks off bootstrap.
///
/// Mutation rules — distinct from `SessionRuntime`:
/// - Every setter is an unconditional write to `config` / `title`.
///   There is no `guard !isAttached`; there is no CLI to talk to.
/// - **No DB writes.** The first persist happens inside
///   `SessionRuntime.fromDraft` at promotion time.
/// - **No RPCs.** `setModel` / `setEffort` / `setPermissionMode` /
///   `setFastMode` / `setAdditionalDirectories` just mutate the
///   config. The launch arg / runtime RPC behavior lives on
///   `SessionRuntime`.
@Observable
@MainActor
final class SessionDraft {

    let sessionId: String
    @ObservationIgnored internal let repository: any SessionRepository

    internal(set) var config: SessionConfig = SessionConfig()
    internal(set) var title: String = ""

    // Presence carries across promotion so the sidebar's running /
    // unread dots survive the draft → runtime transition.
    internal(set) var isFocused: Bool = false
    internal(set) var hasUnread: Bool = false

    init(sessionId: String, repository: any SessionRepository) {
        self.sessionId = sessionId
        self.repository = repository
    }

    /// @MainActor class deinit would otherwise route through
    /// `swift_task_deinitOnExecutorImpl` and hit the same macOS 26 SDK
    /// bug `SessionRuntime` works around. nonisolated deinit skips the
    /// executor-hop path.
    nonisolated deinit {}

    // MARK: - Config setters (draft-only — no CLI, no DB)

    func setCwd(_ cwd: String) {
        config.cwd = cwd
    }

    /// Clear the picked folder back to "no project selected" — the compose
    /// card's `removeFromRecents` of the current folder resets the card to the
    /// "Pick a project" state. (The SwiftUI configurator routed this through a
    /// `@Binding<String?>` whose setter dropped nil writes, so the clear was a
    /// silent no-op there; the AppKit port models it as a first-class draft
    /// capability instead.)
    func clearCwd() {
        config.cwd = nil
    }

    func setWorktree(_ isWorktree: Bool) {
        config.isWorktree = isWorktree
    }

    func setOriginPath(_ originPath: String?) {
        config.originPath = originPath
    }

    func setSourceBranch(_ branch: String?) {
        config.sourceBranch = branch
    }

    func setWorktreeBranch(_ branch: String?) {
        config.worktreeBranch = branch
    }

    func setPluginDirectories(_ dirs: [String]) {
        config.pluginDirectories = dirs
    }

    func setModel(_ model: String) {
        config.model = model
    }

    func setEffort(_ effort: Effort) {
        config.effort = effort
    }

    func setPermissionMode(_ mode: PermissionMode) {
        config.permissionMode = mode
    }

    func setFastMode(_ enabled: Bool) {
        config.fastModeEnabled = enabled
    }

    func setAdditionalDirectories(_ dirs: [String]) {
        config.additionalDirectories = dirs
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        if focused {
            hasUnread = false
        }
    }

    // MARK: - Read accessors (mirror runtime's surface)

    var cwd: String? { config.cwd }
    var isWorktree: Bool { config.isWorktree }
    var originPath: String? { config.originPath }
    var sourceBranch: String? { config.sourceBranch }
    var worktreeBranch: String? { config.worktreeBranch }
    var model: String? { config.model }
    var effort: Effort? { config.effort }
    var permissionMode: PermissionMode { config.permissionMode }
    var fastModeEnabled: Bool { config.fastModeEnabled }
    var additionalDirectories: [String] { config.additionalDirectories }
    var pluginDirectories: [String] { config.pluginDirectories }
}

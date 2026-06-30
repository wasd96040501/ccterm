import AgentSDK
import Foundation

/// Plain-value snapshot of a session's user-facing configuration.
///
/// Acts as the data carried across the draft-to-runtime split: a
/// `SessionDraft` accumulates one of these as the user fills in the
/// compose card, and at promotion time the same value is handed verbatim
/// to the freshly-constructed `SessionRuntime` (and from there, mapped
/// into a `SessionRecord` for the first DB save).
///
/// All fields are settable, even those that the CLI cannot change at
/// runtime (`cwd`, `pluginDirectories`, ...). The "can this field be
/// edited right now?" predicate is encoded in the type that *owns* a
/// `SessionConfig` (draft vs runtime), not on the value type itself.
struct SessionConfig: Equatable {

    /// Working directory the CLI runs in. nil during a draft before
    /// the user has selected a folder; required by the time the runtime
    /// boots.
    var cwd: String?

    /// True iff the session's `cwd` is a git worktree provisioned for
    /// this session (vs the user's plain folder selection).
    var isWorktree: Bool

    /// User-selected source directory. For worktree sessions this is
    /// the base repo the worktree was provisioned from; for plain
    /// sessions it tracks the parent folder selection used by the
    /// "Recent" picker.
    var originPath: String?

    /// Parent branch the worktree should be forked off. Consumed once
    /// by `SessionRuntime` startup and never persisted; nil after
    /// promotion. nil also means "use the base repo's current HEAD".
    var sourceBranch: String?

    /// Branch name of the **provisioned** worktree (set after
    /// `Worktree.create` runs). Persisted; restored on resume.
    var worktreeBranch: String?

    var model: String?
    var effort: Effort?
    var permissionMode: PermissionMode
    var additionalDirectories: [String]
    var pluginDirectories: [String]

    /// Per-session "fast mode" opt-in. Memory-only (the CLI flag is
    /// documented as not persisted across sessions).
    var fastModeEnabled: Bool

    init(
        cwd: String? = nil,
        isWorktree: Bool = false,
        originPath: String? = nil,
        sourceBranch: String? = nil,
        worktreeBranch: String? = nil,
        model: String? = nil,
        effort: Effort? = nil,
        permissionMode: PermissionMode = .default,
        additionalDirectories: [String] = [],
        pluginDirectories: [String] = [],
        fastModeEnabled: Bool = false
    ) {
        self.cwd = cwd
        self.isWorktree = isWorktree
        self.originPath = originPath
        self.sourceBranch = sourceBranch
        self.worktreeBranch = worktreeBranch
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.additionalDirectories = additionalDirectories
        self.pluginDirectories = pluginDirectories
        self.fastModeEnabled = fastModeEnabled
    }

    /// Hydrate from a persisted `SessionRecord`. `sourceBranch` and
    /// `fastModeEnabled` are not persisted — they default to nil/false.
    init(from record: SessionRecord) {
        self.cwd = record.cwd
        self.isWorktree = record.isWorktree
        self.originPath = record.originPath
        self.sourceBranch = nil
        self.worktreeBranch = record.worktreeBranch
        self.model = record.extra.model
        self.effort = record.extra.effort.flatMap(Effort.init(rawValue:))
        if let raw = record.extra.permissionMode,
            let mapped = PermissionMode(rawValue: raw)
        {
            self.permissionMode = mapped
        } else {
            self.permissionMode = .default
        }
        self.additionalDirectories = record.extra.addDirs ?? []
        self.pluginDirectories = record.extra.pluginDirs ?? []
        self.fastModeEnabled = false
    }

    /// `SessionExtra` payload mirror, used as the inner field on
    /// `SessionRecord` for both fresh-saves and incremental updates.
    func toSessionExtra() -> SessionExtra {
        SessionExtra(
            pluginDirs: pluginDirectories.isEmpty ? nil : pluginDirectories,
            permissionMode: permissionMode.rawValue,
            addDirs: additionalDirectories.isEmpty ? nil : additionalDirectories,
            model: model,
            effort: effort?.rawValue
        )
    }

    /// Build the fresh-save `SessionRecord` at promotion time. Caller
    /// supplies `sessionId` (identity) and `title`; everything else
    /// derives from `self`. Status is `.pending` — bootstrap flips it
    /// to `.created` after the CLI's first successful init.
    func toSessionRecord(sessionId: String, title: String) -> SessionRecord {
        SessionRecord(
            sessionId: sessionId,
            title: title,
            cwd: cwd,
            isWorktree: isWorktree,
            originPath: originPath,
            status: .pending,
            extra: toSessionExtra(),
            worktreeBranch: worktreeBranch
        )
    }

    /// Derive the AgentSDK launch configuration. `sessionId` is the
    /// stable handle id; `resume` swaps in `--resume <sid>` when the
    /// caller has decided the CLI must rejoin an existing conversation.
    /// `customCommand` is hoisted from `UserDefaults` by the call site
    /// (the test rule against reading `UserDefaults` from pure
    /// derivation paths still applies — see `cctermTests/CLAUDE.md`).
    /// `messageExportDirectory` is likewise injected: when non-nil the SDK
    /// writes every stdout/stdin JSONL line under it (one file per session
    /// id). The call site passes `SessionConfig.exportDirectory` only when
    /// the debug toggle is on; nil keeps the SDK from writing anything.
    func toAgentSDKConfig(
        sessionId: String,
        resume: Bool,
        customCommand: String?,
        messageExportDirectory: URL? = nil
    ) -> SessionConfiguration {
        let wd = URL(fileURLWithPath: cwd ?? originPath ?? FileManager.default.currentDirectoryPath)
        return SessionConfiguration(
            workingDirectory: wd,
            model: model,
            permissionMode: permissionMode.toSDK(),
            sessionId: resume ? nil : sessionId,
            resume: resume ? sessionId : nil,
            effort: effort,
            // The `.ultracode` tier launches at xhigh (handled by the SDK's
            // `--effort` builder); the ultracode flag itself rides in as an
            // inline flag-settings source so it is live from the first turn.
            settings: effort == .ultracode ? "{\"ultracode\":true}" : nil,
            addDirs: additionalDirectories,
            // Opt into SSE-style partial messages so the renderer can stream
            // assistant text live and track turn token usage as it accrues.
            // Deltas arrive on `Session.onStreamEvent` (wired in
            // `SessionRuntime.attachCallbacks`), never on `onMessage`.
            includePartialMessages: true,
            plugins: pluginDirectories,
            customCommand: customCommand,
            allowDangerouslySkipPermissions: true,
            messageExportDirectory: messageExportDirectory
        )
    }
}

extension SessionConfig {

    /// CCTerm's own raw-message export directory
    /// (`~/.cache/ccterm/export`). Used only when the debug "export session
    /// JSONL" toggle is on; the SDK writes one `<sessionId>.jsonl` here
    /// capturing every byte it forwarded. Not a history source — history
    /// always loads from `~/.claude/projects` (`HistoryLoader`).
    static var exportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/ccterm/export")
    }
}

/// UserDefaults coordinates for the debug "export session JSONL" toggle,
/// shared between the Settings UI (`@AppStorage`) and the launch path
/// (`SessionRuntime.continueStartup`). Default is off.
enum SessionExportDefaults {
    static let enabledKey = "exportSessionJSONL"
}

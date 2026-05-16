import AgentSDK
import Foundation
import Observation

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

    enum HistoryLoadState: Equatable {
        /// loadHistory has never been triggered.
        case notLoaded
        /// Phase A byte-level tail read in progress. UI renders an empty
        /// NativeTranscriptView (the ProgressView was removed — tail is
        /// usually < 50 ms; flashing a spinner is worse).
        case loadingTail
        /// Phase A done; tail is appended to `messages` and renderable.
        /// Phase B full parse continues in the background. `messages` may
        /// keep growing in this state (live appends are not blocked).
        case tailLoaded(count: Int)
        /// Done: Phase B merged in; `messages` contains the full history.
        case loaded
        /// Failed: only triggered by Phase A (tail unreadable). Phase B
        /// failure just logs a warning and the state stays at `.tailLoaded` —
        /// the user already saw the tail, no point un-committing it.
        case failed(String)
    }

    // MARK: - Identity

    let sessionId: String
    internal let repository: any SessionRepository

    // MARK: - Status

    internal(set) var status: Status = .notStarted
    internal(set) var historyLoadState: HistoryLoadState = .notLoaded

    /// Whether a persisted record exists in the repository. Derived from
    /// `repository.find != nil` at init; flipped to true after the fresh
    /// path's `persistConfiguration` runs in `ensureStarted`. UI overlays
    /// use this to distinguish "still a draft" from "promoted to a real
    /// session" and to drive the form-switch animation.
    internal(set) var hasRecord: Bool = false

    /// Description of the most recent launch failure or abnormal process
    /// exit (includes exit code). nil means "didn't happen". Written at
    /// runtime by the process-exit handler; restored from `record.error`
    /// during hydrate.
    internal(set) var termination: String?

    // MARK: - Metadata

    internal(set) var title: String = ""
    internal(set) var originPath: String?
    /// Branch name for worktree sessions. Set to the initial random name
    /// (`<adj>-<sci>-<hex6>`) when fresh + isWorktree completes
    /// `ensureStarted()`; never changes afterward. nil for non-worktree.
    internal(set) var worktreeBranch: String?
    /// True while title generation is running asynchronously. UI uses this
    /// for shimmer/loading. Triggered by `generateTitle(from:)`, reset when
    /// `Prompt.runTitleAndBranch` finishes.
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

    /// Message timeline. SwiftUI renderers (sidebar / metrics / ...) read
    /// this `@Observable` field directly; the AppKit renderer goes through
    /// the `onMessagesChange` synchronous callback for incremental
    /// instructions and does not re-read here.
    internal(set) var messages: [MessageEntry] = []

    /// AppKit-renderer outgoing sink. After every `messages` write, the
    /// handle synchronously fires one `MessagesChange` in the same call
    /// stack describing exactly what changed.
    ///
    /// Intent: the bridge translates the instruction straight into
    /// `Transcript2Controller.apply(...)`, avoiding both a full-table diff
    /// and the extra main-actor hop of AsyncStream / @Observable.
    ///
    /// nil = no bridge attached; writes proceed normally, the sink is
    /// skipped.
    ///
    /// Closure rather than protocol: the bridge type lives in the view
    /// module, so the declaration here can only be a closure / anonymous
    /// type. Weak ownership is solved inside the closure (`[weak bridge]`).
    @ObservationIgnored var onMessagesChange: ((MessagesChange) -> Void)?

    /// CLI launch-failure callback. Every launch-time failure path (sync
    /// `Process.run` throwing, or the CLI exiting before init completes)
    /// funnels into `failLaunch(reason:)`, which fires this synchronously
    /// once with the raw, unlocalized description. The subscriber
    /// (SessionManager2) forwards it to the UI alert.
    ///
    /// Closure-injected like `onMessagesChange`, to keep UI types out of
    /// the handle. Weak handling lives in the subscriber's closure.
    @ObservationIgnored var onLaunchFailure: ((String) -> Void)?

    /// Hook installed during the bootstrap init wait so
    /// `handleProcessExit` can route "died before init" back into the
    /// bootstrap continuation. Without it, `initialize` would never
    /// complete and the Task would hang. Cleared on exit from the init
    /// wait.
    @ObservationIgnored internal var bootstrapExitHook: ((Int32) -> Void)?

    /// In-flight turn count. `+1` on every `send(_:)` entry, `-1` on every
    /// `.result`, reset to 0 on process abort or explicit interrupt.
    /// `isRunning` derives from this — the view layer (loading pill,
    /// InputBar's send↔stop) reads `isRunning` as the source of truth.
    ///
    /// Why not derive from `status`: there's a ~200 ms gap between
    /// `.idle` and `.responding` (send → CLI echo round trip), and a
    /// message sent in that gap can't flip "running" via status alone.
    /// The turn count is `+1` synchronously at send entry, with no delay.
    internal(set) var pendingTurnCount: Int = 0

    /// "Is something running?" — read this in the view layer. True between
    /// `.send(_:)` and `.result` / `interrupt`. Counts overlapping turns
    /// when multiple user messages are in flight.
    var isRunning: Bool { pendingTurnCount > 0 }

    internal(set) var pendingPermissions: [PendingPermission] = []
    internal(set) var contextUsedTokens: Int = 0
    internal(set) var contextWindowTokens: Int = 0
    internal(set) var slashCommands: [SlashCommand] = []
    internal(set) var availableModels: [String] = []

    // MARK: - Presence

    internal(set) var isFocused: Bool = false
    internal(set) var hasUnread: Bool = false

    // MARK: - Internal runtime

    /// Bound AgentSDK subprocess. Assigned after a successful
    /// `session.start()` in bootstrap; cleared on process exit / stop.
    internal var agentSession: AgentSDK.Session?

    /// Accumulated stderr buffer. Written into `termination` on process
    /// exit. Not persisted.
    @ObservationIgnored internal var stderrBuffer: String = ""

    /// Test-only hook: when true, `ensureStarted()` returns immediately
    /// after the synchronous setup without launching the bootstrap Task or
    /// touching the CLI. Used for pure DB / state assertions. Must not be
    /// set by production code.
    @ObservationIgnored internal var skipBootstrapForTesting: Bool = false

    // MARK: - Init

    /// Create the handle. **No separate fresh / resume init** —
    /// `sessionId` is identity; the handle distinguishes new vs existing
    /// sessions internally via `repository`.
    ///
    /// Behavior:
    /// - Synchronously reads `repository.find(sessionId)` and applies
    ///   persisted fields: `title` / `cwd` / `isWorktree` / `originPath` /
    ///   `worktreeBranch` / `termination` / `model` / `effort` /
    ///   `permissionMode` / `additionalDirectories` / `pluginDirectories`
    ///   (defaults when no record).
    /// - **Does not load history.** `messages` is empty,
    ///   `historyLoadState = .notLoaded`. The UI calls `loadHistory()`
    ///   explicitly when entering the session view; this is decoupled from
    ///   `activate()`.
    /// - `status = .notStarted`.
    ///
    /// ## DB write timing (master rule for every method)
    ///
    /// - `init`: **no db write** (pure in-memory construction; even when
    ///   the sessionId has no record, do not create an orphan).
    /// - `set*` config commands while `.notStarted`: write fields only
    ///   (in-memory draft), **no db**.
    /// - First `ensureStarted()` (triggered by `activate()` or `send(_:)`):
    ///   `save` the current full configuration to db in one shot.
    /// - Field changes after start (CLI init reply / non-active edits):
    ///   `didSet` triggers `repository.updateXxx` for an incremental update.
    ///
    /// ## Setter mutability matrix
    ///
    /// | setter | while attached | exposed canSet* |
    /// |---|---|---|
    /// | `setModel` / `setEffort` / `setPermissionMode` | local + db + RPC | — (always callable) |
    /// | `setAdditionalDirectories` | local + db + applyFlagSettings RPC | — (always callable) |
    /// | `setCwd` / `setWorktree` | no-op (CLI runtime can't change it) | `canSetCwd` / `canSetWorktree` |
    /// | `setPluginDirectories` | no-op (`--plugin-dir` is launch-only) | `canSetPluginDirectories` |
    /// | `setFocused` | local (does not touch CLI) | — (always callable) |
    /// | `respond(to:decision:)` | local (only effective when a pending matches) | — |
    init(sessionId: String, repository: any SessionRepository) {
        self.sessionId = sessionId
        self.repository = repository
        if let record = repository.find(sessionId) {
            hasRecord = true
            apply(record)
        }
    }

    /// @MainActor class deinit would otherwise route through
    /// `swift_task_deinitOnExecutorImpl`, hitting a macOS 26 SDK bug in
    /// libswift_Concurrency (`TaskLocal::StopLookupScope` deinit frees an
    /// un-malloc'd pointer → abort). nonisolated deinit skips the
    /// executor-hop path and avoids the bug.
    nonisolated deinit {}

    /// Map the persisted fields from `record` onto this handle. Only
    /// touches fields; does not touch status / messages.
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
            let mapped = PermissionMode(rawValue: raw)
        {
            permissionMode = mapped
        }
        additionalDirectories = record.extra.addDirs ?? []
        pluginDirectories = record.extra.pluginDirs ?? []
    }

    // MARK: - Lifecycle commands

    // `activate()` / `stop()` / `send(_:)` implementations and docs live in
    // `SessionHandle2+Start.swift`.

    /// Load history messages into `messages` in the background. Idempotent,
    /// dispatched by `historyLoadState`.
    ///
    /// - `.notLoaded`: two-phase read. `historyLoadState` → `.loadingTail`
    ///   → `.tailLoaded(count)` → `.loaded`; tail renders first, prefix
    ///   merges in the background. Parse failure → `.failed(reason)`.
    /// - `.loadingTail` / `.tailLoaded`: no-op (prevents reentry / Phase B
    ///   in flight).
    /// - `.loaded`: no-op.
    /// - `.failed`: retry — flips back to `.notLoaded` and reloads.
    ///
    /// The method does not block its caller; the UI observes
    /// `historyLoadState` for spinner / error display. Independent of
    /// `activate()` — stopped / notStarted sessions can still view history.
    // impl in SessionHandle2+History.swift

    // MARK: - Messaging commands

    /// Interrupt the current model response.
    ///
    /// - `.responding`: `status` → `.interrupting`; → `.idle` after SDK ack.
    /// - Other statuses: no-op.
    // impl in SessionHandle2+Messaging.swift

    /// Cancel an unsent or failed message.
    ///
    /// - Target entry delivery is `.queued` / `.failed`: remove from `messages`.
    /// - delivery is `.confirmed`: no-op (CLI is already processing; local
    ///   removal can't stop it).
    /// - id missing or not a user entry: no-op.
    // impl in SessionHandle2+Messaging.swift

    // MARK: - Configuration commands

    /// Change model. **Optimistic write** semantics:
    ///
    /// - `.notStarted` / `.stopped` (non-active): mutate memory only; used
    ///   as a launch arg by the next `ensureStarted`.
    /// - Attached (`.idle` / `.responding` / `.interrupting` / `.starting`):
    ///   1. **Mutate memory immediately** (UI feedback now, avoiding the
    ///      100-300ms RPC round trip).
    ///   2. Concurrently send the RPC to the CLI.
    ///   3. The CLI's subsequent init/config replies are **authoritative**:
    ///      if they disagree with our local guess, the reply overwrites
    ///      memory (no rollback — reply is truth).
    // impl in SessionHandle2+Configuration.swift

    /// Change effort. Same routing as `setModel` (optimistic write + RPC +
    /// reply-overrides).
    // impl in SessionHandle2+Configuration.swift

    /// Change permission mode. Same routing as `setModel` (optimistic write
    /// + RPC + reply-overrides).
    // impl in SessionHandle2+Configuration.swift

    /// Change working directory.
    ///
    /// - Non-active (`.notStarted` / `.stopped`): local write to `cwd`.
    /// - Active: no-op (CLI runtime can't change cwd; `stop()` first).
    // impl in SessionHandle2+Configuration.swift

    /// Change worktree flag. Same routing as `setCwd` (cannot change at
    /// runtime).
    // impl in SessionHandle2+Configuration.swift

    /// Change additional-directories list. **Mutable at runtime** —
    /// attached writes go through
    /// `applyFlagSettings.permissions.additionalDirectories`. UI layer
    /// adds/removes single entries with read-modify-write:
    /// `handle.setAdditionalDirectories(handle.additionalDirectories + [path])`.
    // impl in SessionHandle2+Configuration.swift

    /// Change plugin-directories list. Same routing as `setCwd`
    /// (`--plugin-dir` is a CLI launch argument with no runtime RPC). UI
    /// uses `canSetPluginDirectories` to disable the entry point.
    // impl in SessionHandle2+Configuration.swift

    // MARK: - Permission

    /// Reply to a pending permission.
    ///
    /// - Found in `pendingPermissions`: call its respond closure (auto-
    ///   replies to CLI and removes from the array).
    /// - id missing: no-op.
    // impl in SessionHandle2+Configuration.swift

    // MARK: - Presence

    /// UI sets "is this session currently being viewed". The handle never
    /// flips this on its own.
    ///
    /// - `setFocused(true)`: also clears `hasUnread = false`.
    /// - `setFocused(false)`: only sets `isFocused`; leaves `hasUnread`.
    ///
    /// Call sites (UI layer responsibility):
    /// - `ChatRouter.activateSession` on switch: write false on the old
    ///   handle, true on the new one.
    /// - `AppState` observing NSWindow lose/regain focus: write the
    ///   matching value on the currently-displayed handle.
    // impl in SessionHandle2+Configuration.swift
}

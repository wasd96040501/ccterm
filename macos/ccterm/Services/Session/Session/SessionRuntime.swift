import AgentSDK
import Foundation
import Observation

/// The runtime engine for one active chat session.
///
/// Owns everything bound to a live CLI subprocess: status, messages,
/// pending turns / permissions, the CLI client itself, history load
/// state, the model catalog. The runtime is constructed *after* the
/// session has been promoted from draft (via the `fromDraft` factory) or
/// hydrated from an existing record (regular init).
///
/// `Session` is the UI-facing façade that wraps either a `SessionDraft`
/// or a `SessionRuntime` and forwards reads/writes appropriately; views
/// should not interact with `SessionRuntime` directly.
@Observable
@MainActor
final class SessionRuntime {

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
    /// True while title generation is running asynchronously. UI uses this
    /// for shimmer/loading. Triggered by `generateTitle(from:)`, reset when
    /// `Prompt.runTitleAndBranch` finishes.
    internal(set) var isGeneratingTitle: Bool = false

    // MARK: - Configuration
    //
    // All user-facing configuration (cwd / worktree / dirs / model /
    // effort / permission mode / additional+plugin dirs / fast mode)
    // lives on `config`. The accessors below preserve the historical
    // dot-property read surface (`runtime.cwd` / `runtime.model` etc.)
    // while routing every read through the single value-type field.
    // Mutation goes through `setModel(_:)` etc. (runtime-mutable
    // setters in `SessionRuntime+Configuration.swift`); the cwd /
    // worktree / source-branch / plugin-dir setters live exclusively
    // on `SessionDraft` — at the runtime layer those values are
    // launch-only and not user-editable.
    internal(set) var config: SessionConfig = SessionConfig()

    var cwd: String? {
        get { config.cwd }
        set { config.cwd = newValue }
    }
    var isWorktree: Bool {
        get { config.isWorktree }
        set { config.isWorktree = newValue }
    }
    var originPath: String? {
        get { config.originPath }
        set { config.originPath = newValue }
    }
    var sourceBranch: String? {
        get { config.sourceBranch }
        set { config.sourceBranch = newValue }
    }
    var worktreeBranch: String? {
        get { config.worktreeBranch }
        set { config.worktreeBranch = newValue }
    }
    var model: String? {
        get { config.model }
        set { config.model = newValue }
    }
    var effort: Effort? {
        get { config.effort }
        set { config.effort = newValue }
    }
    var permissionMode: PermissionMode {
        get { config.permissionMode }
        set { config.permissionMode = newValue }
    }
    var fastModeEnabled: Bool {
        get { config.fastModeEnabled }
        set { config.fastModeEnabled = newValue }
    }
    var additionalDirectories: [String] {
        get { config.additionalDirectories }
        set { config.additionalDirectories = newValue }
    }
    var pluginDirectories: [String] {
        get { config.pluginDirectories }
        set { config.pluginDirectories = newValue }
    }

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
    /// (SessionManager) forwards it to the UI alert.
    ///
    /// Closure-injected like `onMessagesChange`, to keep UI types out of
    /// the handle. Weak handling lives in the subscriber's closure.
    @ObservationIgnored var onLaunchFailure: ((String) -> Void)?

    /// Fresh-session persisted callback. Fires once, synchronously, right
    /// after `repository.save(record)` writes the new row in
    /// `persistConfiguration`'s `!hasRecord` branch. The subscriber
    /// (SessionManager) re-reads `records` so the sidebar surfaces the
    /// new session.
    ///
    /// Needed because the worktree-provisioning path runs the save
    /// asynchronously (after `Worktree.create` returns 10-20s later) — by
    /// then RootView2's inline `refreshRecords()` call has already executed
    /// against an empty repo, so without this callback the sidebar stays
    /// stale until the next refresh-triggering event.
    @ObservationIgnored var onRecordPersisted: (() -> Void)?

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
    /// Model catalog from the CLI's `InitializeResponse.models`. Source of
    /// truth for the model picker — display name, supported effort levels,
    /// and feature flags (auto / fast / adaptive thinking) per model. Set
    /// once at bootstrap, then mirrored into `ModelStore` for sessions that
    /// haven't started yet (the compose-mode picker reads the cache).
    internal(set) var availableModels: [ModelInfo] = []

    // MARK: - Presence

    internal(set) var isFocused: Bool = false
    internal(set) var hasUnread: Bool = false

    // MARK: - Internal runtime

    /// Bound CLI subprocess wrapper. Assigned after a successful
    /// `client.start()` in bootstrap; cleared on process exit / stop.
    /// Concrete type is decided by `cliClientFactory` — production wires
    /// `AgentSDKCLIClient`, tests inject `FakeCLIClient`.
    internal var cliClient: (any CLIClient)?

    /// Factory used to construct the per-bootstrap CLI client from the
    /// derived `SessionConfiguration`. Captured at init so the handle
    /// stays agnostic of the underlying SDK type; default is
    /// `AgentSDKCLIClient.defaultFactory`.
    @ObservationIgnored internal let cliClientFactory: CLIClientFactory

    /// Accumulated stderr buffer. Written into `termination` on process
    /// exit. Not persisted.
    @ObservationIgnored internal var stderrBuffer: String = ""

    // MARK: - Init

    /// Construct the runtime. `sessionId` is identity; if `repository`
    /// already has a matching record, `apply(_:)` hydrates the runtime
    /// from it (title / cwd / worktree / dirs / model / effort /
    /// permission mode / pluginDirectories / termination) — that's the
    /// resume path. Otherwise the runtime starts empty and waits for
    /// `Session.fromDraft` to copy a config in.
    ///
    /// - **Does not load history.** `messages` is empty,
    ///   `historyLoadState = .notLoaded`. The UI calls `loadHistory()`
    ///   explicitly when entering the session view; this is decoupled
    ///   from `activate()`.
    /// - `status = .notStarted`. Bootstrap runs on the first
    ///   `activate()` / `send(_:)` (or `ensureStarted()` from inside
    ///   `Session.send`'s promotion path).
    ///
    /// ## DB write timing (master rule for every runtime method)
    ///
    /// - `init`: **no db write** (pure in-memory construction; even when
    ///   the sessionId has no record, do not create an orphan).
    /// - First `ensureStarted()` (triggered by `activate()` or
    ///   `send(_:)`): `save` the current full configuration to db in
    ///   one shot.
    /// - Field changes after start (CLI init reply / `setModel` /
    ///   `setEffort` / `setPermissionMode` / `setAdditionalDirectories`):
    ///   each setter calls `repository.updateXxx` for an incremental
    ///   update.
    ///
    /// ## Setter behavior on the runtime
    ///
    /// | setter | semantics |
    /// |---|---|
    /// | `setModel` / `setEffort` / `setPermissionMode` | local + db + RPC; CLI's init/config replies are authoritative |
    /// | `setAdditionalDirectories` | local + db + `applyFlagSettings` RPC |
    /// | `setFastMode` | local + (when attached) RPC |
    /// | `setFocused` | local (does not touch CLI) |
    /// | `respond(to:decision:)` | local (only effective when a pending matches) |
    ///
    /// **Draft-only setters** (`setCwd` / `setWorktree` /
    /// `setOriginPath` / `setSourceBranch` / `setPluginDirectories`)
    /// live on `SessionDraft` instead — the runtime cannot meaningfully
    /// re-edit the CLI's launch arguments mid-flight.
    init(
        sessionId: String,
        repository: any SessionRepository,
        cliClientFactory: @escaping CLIClientFactory = AgentSDKCLIClient.defaultFactory
    ) {
        self.sessionId = sessionId
        self.repository = repository
        self.cliClientFactory = cliClientFactory
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
        termination = record.error
        config = SessionConfig(from: record)
    }

    // MARK: - Lifecycle commands

    // `activate()` / `stop()` / `send(_:)` implementations and docs live in
    // `SessionRuntime+Start.swift`.

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
    // impl in SessionRuntime+History.swift

    // MARK: - Messaging commands

    /// Interrupt the current model response.
    ///
    /// - `.responding`: `status` → `.interrupting`; → `.idle` after SDK ack.
    /// - Other statuses: no-op.
    // impl in SessionRuntime+Messaging.swift

    /// Cancel an unsent or failed message.
    ///
    /// - Target entry delivery is `.queued` / `.failed`: remove from `messages`.
    /// - delivery is `.confirmed`: no-op (CLI is already processing; local
    ///   removal can't stop it).
    /// - id missing or not a user entry: no-op.
    // impl in SessionRuntime+Messaging.swift

    // MARK: - Configuration commands

    /// Change model. **Optimistic write** semantics:
    ///
    /// - Detached (`.notStarted` / `.stopped`): mutate memory only; used
    ///   as a launch arg by the next `ensureStarted`.
    /// - Attached (`.idle` / `.responding` / `.interrupting` / `.starting`):
    ///   1. **Mutate memory immediately** (UI feedback now, avoiding the
    ///      100-300ms RPC round trip).
    ///   2. Concurrently send the RPC to the CLI.
    ///   3. The CLI's subsequent init/config replies are **authoritative**:
    ///      if they disagree with our local guess, the reply overwrites
    ///      memory (no rollback — reply is truth).
    // impl in SessionRuntime+Configuration.swift

    /// Change effort. Same routing as `setModel` (optimistic write + RPC +
    /// reply-overrides).
    // impl in SessionRuntime+Configuration.swift

    /// Change permission mode. Same routing as `setModel` (optimistic write
    /// + RPC + reply-overrides).
    // impl in SessionRuntime+Configuration.swift

    /// Change additional-directories list. **Mutable at runtime** —
    /// attached writes go through
    /// `applyFlagSettings.permissions.additionalDirectories`. UI layer
    /// adds/removes single entries with read-modify-write:
    /// `runtime.setAdditionalDirectories(runtime.additionalDirectories + [path])`.
    // impl in SessionRuntime+Configuration.swift
    // impl in SessionRuntime+Configuration.swift

    // MARK: - Permission

    /// Reply to a pending permission.
    ///
    /// - Found in `pendingPermissions`: call its respond closure (auto-
    ///   replies to CLI and removes from the array).
    /// - id missing: no-op.
    // impl in SessionRuntime+Configuration.swift

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
    // impl in SessionRuntime+Configuration.swift
}

import AgentSDK
import Foundation
import Observation

/// UI-facing façade for a single chat session.
///
/// Internally `Session` is in one of two phases:
/// - `.draft(SessionDraft)`: the user is still configuring a New
///   Session card; no CLI, no persisted record, no messages.
/// - `.active(SessionRuntime)`: the session has been promoted; a
///   runtime owns the CLI subprocess, the message timeline, history
///   load state, etc.
///
/// The phase flips exactly once: a draft session sending its first
/// message constructs a `SessionRuntime` via
/// `SessionRuntime.fromDraft(...)`, wires the bridge sinks onto the
/// new runtime, then swaps `phase` to `.active`. After that, every
/// subsequent send / interrupt / setter routes to the runtime.
///
/// Views never inspect `phase` directly — they read forwarding
/// properties (`session.title`, `session.messages`, `session.isRunning`,
/// `session.status` …) which dispatch on the current phase under the
/// hood. The escape hatches `session.draft` / `session.runtime` are
/// available for callers that need to issue a draft-only setter
/// (`session.draft?.setCwd(...)`) or talk to the runtime by name.
///
/// ## Render-side state
///
/// `Session` also owns the transcript's render-side state machine —
/// `controller` (`Transcript2Controller`) and `bridge`
/// (`Transcript2EntryBridge`) — and wires the bridge to the runtime
/// at session creation / promotion. This makes the bridge a continuous
/// consumer of `runtime.onMessagesChange`: live CLI events flow into
/// the controller's block list **even when no transcript view is
/// mounted**, so the user switching the sidebar to another session
/// doesn't pause renderer-side processing for the session they left.
/// `TranscriptDetailViewController` binds the controller's `coordinator`
/// (which has a `weak NSTableView`) to a fresh `NSTableView` on each
/// mount via `TranscriptScrollViewFactory.make`; when no table is bound,
/// the coordinator still updates its `blocks` array and skips AppKit
/// calls — a re-attach picks up the accumulated state through the host's
/// `view.layoutSubtreeIfNeeded()`, which sizes the table from `.zero`
/// to its real frame and drives `NSTableView.tile()` inline.
@Observable
@MainActor
final class Session {

    enum Phase {
        case draft(SessionDraft)
        case active(SessionRuntime)
    }

    /// Stable across the draft → active flip — the draft's sessionId
    /// becomes the runtime's sessionId verbatim. UI uses this as the
    /// identity key for view binding / observation.
    let sessionId: String

    internal(set) var phase: Phase

    @ObservationIgnored internal let repository: any SessionRepository
    @ObservationIgnored internal let cliClientFactory: CLIClientFactory

    /// Fired synchronously after the draft → active phase flip
    /// completes. `SessionManager` wires this to `refreshRecords()` so
    /// the sidebar surfaces the newly persisted session immediately.
    @ObservationIgnored internal var onPromoted: ((SessionRuntime) -> Void)?

    // MARK: - Render-side state (continuous lifetime)

    /// Imperative transcript controller. Lives as long as the session
    /// does — survives transcript-view mount/dismount cycles. Views
    /// read `session.controller` and hand it to the transcript host
    /// (production: `TranscriptDetailViewController`); they never
    /// construct their own.
    let controller: Transcript2Controller

    /// Renderer-side translator: subscribes to the runtime's
    /// `onMessagesChange` and converts each `MessagesChange` into
    /// `Transcript2Controller.apply / setHistory` calls. The bridge
    /// is wired to the runtime exactly once — at `Session.init` for
    /// `.active`-from-record sessions, at promotion time for
    /// draft → active sessions — and stays wired for the session's
    /// entire lifetime.
    let bridge: Transcript2EntryBridge

    /// History backfill pipeline, alive for the duration of one load. Created
    /// by `loadHistory()` and retained so its off-main producer task isn't
    /// torn down mid-flight. Re-entry is gated by `historyLoadState`, so at
    /// most one ever runs per session.
    @ObservationIgnored private var backfillPipeline: TranscriptBackfillPipeline?

    // MARK: - External hooks

    /// Optional **external** observer of `MessagesChange` events. The
    /// internal `bridge` is the primary consumer (always wired); this
    /// is an additional fanout slot for tests / debugging that need to
    /// observe what the bridge sees. The runtime's sink invokes
    /// `bridge.apply` **then** this closure — both fire synchronously
    /// inside the same `messages` write.
    @ObservationIgnored var onMessagesChange: ((MessagesChange) -> Void)?

    /// Launch-failure sink, forwarded to the runtime when one exists.
    @ObservationIgnored var onLaunchFailure: ((String) -> Void)? {
        didSet {
            runtime?.onLaunchFailure = onLaunchFailure
        }
    }

    /// Fresh-save / async-patch sink, forwarded to the runtime when one
    /// exists. `SessionManager` wires this to `refreshRecords()` so the
    /// sidebar picks up rows whose db row is saved asynchronously
    /// (worktree-provisioning collision-recovery, etc.).
    @ObservationIgnored var onRecordPersisted: (() -> Void)? {
        didSet {
            runtime?.onRecordPersisted = onRecordPersisted
        }
    }

    /// Turn-end signal, forwarded to the runtime when one exists.
    /// `SessionManager` wires this through to its own sink, which the
    /// notification service subscribes to. Draft phase has no runtime,
    /// so the setter is a no-op there; the wiring re-attaches in
    /// `wireRuntimeMessagesSink` at promotion time.
    @ObservationIgnored var onTurnEnded: ((TurnEndedNotice) -> Void)? {
        didSet {
            runtime?.onTurnEnded = onTurnEnded
        }
    }

    // MARK: - Init

    /// Construct from an existing record. `phase` is `.active` with a
    /// runtime hydrated from `record`; the CLI is **not** activated —
    /// the caller invokes `activate()` when ready.
    init(
        record: SessionRecord,
        repository: any SessionRepository,
        cliClientFactory: @escaping CLIClientFactory,
        onPromoted: ((SessionRuntime) -> Void)? = nil
    ) {
        self.sessionId = record.sessionId
        self.repository = repository
        self.cliClientFactory = cliClientFactory
        self.onPromoted = onPromoted
        self.controller = Transcript2Controller()
        self.bridge = Transcript2EntryBridge(controller: controller)
        let runtime = SessionRuntime(
            sessionId: record.sessionId,
            repository: repository,
            cliClientFactory: cliClientFactory
        )
        self.phase = .active(runtime)
        wireRuntimeMessagesSink(runtime)
    }

    /// Construct from a fresh sessionId (no record yet). `phase` is
    /// `.draft` — the user can mutate `draft?.config` via
    /// `setCwd` / `setWorktree` / etc. until `send(...)` promotes.
    init(
        draftSessionId: String,
        repository: any SessionRepository,
        cliClientFactory: @escaping CLIClientFactory,
        onPromoted: ((SessionRuntime) -> Void)? = nil
    ) {
        self.sessionId = draftSessionId
        self.repository = repository
        self.cliClientFactory = cliClientFactory
        self.onPromoted = onPromoted
        self.controller = Transcript2Controller()
        self.bridge = Transcript2EntryBridge(controller: controller)
        self.phase = .draft(
            SessionDraft(sessionId: draftSessionId, repository: repository))
    }

    /// Wrap a pre-built `SessionRuntime` in `.active` phase. Lets
    /// snapshot tests and other harness code seed runtime fields
    /// directly (the runtime is constructed and configured by the
    /// caller) without standing up a `SessionManager` or persisting a
    /// record. Production code paths use the `record:` or
    /// `draftSessionId:` initializers; this one is for assembling a
    /// view-renderable façade out of a runtime fixture.
    init(
        runtime: SessionRuntime,
        cliClientFactory: @escaping CLIClientFactory = AgentSDKCLIClient.defaultFactory,
        onPromoted: ((SessionRuntime) -> Void)? = nil
    ) {
        self.sessionId = runtime.sessionId
        self.repository = runtime.repository
        self.cliClientFactory = cliClientFactory
        self.onPromoted = onPromoted
        self.controller = Transcript2Controller()
        self.bridge = Transcript2EntryBridge(controller: controller)
        self.phase = .active(runtime)
        wireRuntimeMessagesSink(runtime)
    }

    nonisolated deinit {}

    /// Permanently attach the bridge (+ optional external observer) to
    /// `runtime.onMessagesChange`. Called from each `.active`-producing
    /// init, and from `promoteOrForward` at the draft → active flip.
    /// The closure captures `self` weakly because the runtime is
    /// owned by `Session` and would otherwise form a retain cycle.
    private func wireRuntimeMessagesSink(_ runtime: SessionRuntime) {
        runtime.onMessagesChange = { [weak self] change in
            guard let self else { return }
            self.bridge.apply(change)
            self.onMessagesChange?(change)
        }
        runtime.onTurnFinishedLive = { [weak self] in
            self?.bridge.handleTurnFinished()
        }
        runtime.onLaunchFailure = onLaunchFailure
        runtime.onRecordPersisted = onRecordPersisted
        runtime.onTurnEnded = onTurnEnded
    }

    // MARK: - Phase accessors

    /// Non-nil iff `phase == .draft`. Use for draft-only setters
    /// (`session.draft?.setCwd(...)`); after promotion the draft is
    /// retired and this returns nil.
    var draft: SessionDraft? {
        if case .draft(let d) = phase { return d }
        return nil
    }

    /// Non-nil iff `phase == .active`. Use when you specifically need
    /// the runtime (e.g. CLI-only state on init unit tests). UI binding
    /// should prefer the forwarding properties on `Session` directly.
    var runtime: SessionRuntime? {
        if case .active(let r) = phase { return r }
        return nil
    }

    /// True iff `phase == .active`. Mirror of the old
    /// `Session.hasRecord` predicate — the UI still uses this to
    /// distinguish "still a draft" from "promoted".
    var hasRecord: Bool {
        if case .active = phase { return true }
        return false
    }

    // MARK: - Forwarded state reads

    var title: String {
        switch phase {
        case .draft(let d): return d.title
        case .active(let r): return r.title
        }
    }

    var status: SessionRuntime.Status {
        runtime?.status ?? .notStarted
    }

    var historyLoadState: SessionRuntime.HistoryLoadState {
        runtime?.historyLoadState ?? .notLoaded
    }

    var termination: String? {
        runtime?.termination
    }

    var isGeneratingTitle: Bool {
        runtime?.isGeneratingTitle ?? false
    }

    var messages: [MessageEntry] {
        runtime?.messages ?? []
    }

    var isRunning: Bool {
        runtime?.isRunning ?? false
    }

    var pendingPermissions: [PendingPermission] {
        runtime?.pendingPermissions ?? []
    }

    var availableModels: [ModelInfo] {
        runtime?.availableModels ?? []
    }

    var slashCommands: [SlashCommand] {
        runtime?.slashCommands ?? []
    }

    var tasks: [BackgroundTask] {
        runtime?.tasks ?? []
    }

    var todos: [TodoEntry] {
        runtime?.todos ?? []
    }

    var contextUsedTokens: Int {
        runtime?.contextUsedTokens ?? 0
    }

    var contextWindowTokens: Int {
        runtime?.contextWindowTokens ?? 0
    }

    var isFocused: Bool {
        switch phase {
        case .draft(let d): return d.isFocused
        case .active(let r): return r.isFocused
        }
    }

    var hasUnread: Bool {
        switch phase {
        case .draft(let d): return d.hasUnread
        case .active(let r): return r.hasUnread
        }
    }

    // Config-forwarded reads (read from whichever phase owns config now).
    var cwd: String? {
        switch phase {
        case .draft(let d): return d.cwd
        case .active(let r): return r.cwd
        }
    }
    var isWorktree: Bool {
        switch phase {
        case .draft(let d): return d.isWorktree
        case .active(let r): return r.isWorktree
        }
    }
    var originPath: String? {
        switch phase {
        case .draft(let d): return d.originPath
        case .active(let r): return r.originPath
        }
    }
    var sourceBranch: String? {
        switch phase {
        case .draft(let d): return d.sourceBranch
        case .active(let r): return r.sourceBranch
        }
    }
    var worktreeBranch: String? {
        switch phase {
        case .draft(let d): return d.worktreeBranch
        case .active(let r): return r.worktreeBranch
        }
    }
    var model: String? {
        switch phase {
        case .draft(let d): return d.model
        case .active(let r): return r.model
        }
    }
    var effort: Effort? {
        switch phase {
        case .draft(let d): return d.effort
        case .active(let r): return r.effort
        }
    }
    var permissionMode: PermissionMode {
        switch phase {
        case .draft(let d): return d.permissionMode
        case .active(let r): return r.permissionMode
        }
    }
    var fastModeEnabled: Bool {
        switch phase {
        case .draft(let d): return d.fastModeEnabled
        case .active(let r): return r.fastModeEnabled
        }
    }
    var additionalDirectories: [String] {
        switch phase {
        case .draft(let d): return d.additionalDirectories
        case .active(let r): return r.additionalDirectories
        }
    }
    var pluginDirectories: [String] {
        switch phase {
        case .draft(let d): return d.pluginDirectories
        case .active(let r): return r.pluginDirectories
        }
    }

    // MARK: - Lifecycle

    /// Activate the underlying runtime if one exists. No-op on `.draft`
    /// (a draft has nothing to activate — the user has to send a
    /// message to trigger promotion + activation).
    func activate() {
        runtime?.activate()
    }

    func stop() {
        runtime?.stop()
    }

    /// Async variant of `stop()` used by the app-quit shutdown path —
    /// returns only after the CLI has actually exited (or after the
    /// SDK's per-process graceful-shutdown timeout fires SIGTERM). On
    /// a draft session, no runtime exists and this is a no-op.
    func closeAsync() async {
        await runtime?.closeAsync()
    }

    func interrupt() {
        runtime?.interrupt()
    }

    func cancelMessage(id: UUID) {
        runtime?.cancelMessage(id: id)
    }

    /// Drive a one-shot reverse-streaming history load into the controller.
    ///
    /// Idempotent through `runtime.historyLoadState`: `.loading` / `.loaded`
    /// are no-ops (the bridge has been streaming live events into the
    /// controller the whole time, so a re-entered session needs no replay).
    /// Drafts have no history.
    ///
    /// The pipeline applies blocks **directly** to `controller` (load path =
    /// iterator → apply, REFACTOR-PLAN §4.6); the bridge handles only the live
    /// path. History tool statuses route back through the bridge's historical
    /// derivation so failed / completed colors survive.
    func loadHistory(overrideURL: URL? = nil, tailTarget: Int = 80) {
        guard let runtime else { return }
        switch runtime.historyLoadState {
        case .loading, .loaded:
            return
        case .notLoaded:
            break
        }
        runtime.historyLoadState = .loading

        let url = overrideURL ?? runtime.historyJSONLURL
        let pipeline = TranscriptBackfillPipeline(
            source: JSONLReversePageSource(url: url, tailTarget: tailTarget),
            controller: controller,
            onLoaded: { [weak self] in self?.runtime?.historyLoadState = .loaded },
            onApplied: { [weak self] entries in
                self?.bridge.pushHistoricalStatuses(for: entries)
            })
        self.backfillPipeline = pipeline
        // Seed the off-main typeset width from the settled, clamped row width.
        // `loadHistory` runs after the attach tick's `scrollToTail`, so the
        // table geometry has settled and `controller.layoutWidth` is real
        // (REFACTOR-PLAN §6 TICK 1). Headless callers (no table) pass 0; their
        // pages self-heal on the first real `heightOfRow` (§4.3).
        pipeline.trigger(width: controller.layoutWidth)
    }

    func generateTitle(from firstMessage: String) {
        runtime?.generateTitle(from: firstMessage)
    }

    // MARK: - Send (triggers promotion on .draft)

    /// Send a text message. In `.draft` phase, this promotes via
    /// `SessionRuntime.fromDraft(...)` and queues the message as the
    /// first turn. In `.active` phase, forwards to the runtime.
    func send(text: String, planContent: String? = nil) {
        let input = LocalUserInput(text: text, planContent: planContent)
        promoteOrForward(input: input) { runtime in
            runtime.send(text: text, planContent: planContent)
        }
    }

    /// Send a message with one or more inline images plus an optional
    /// caption. Packed as a single user message (text + N image blocks
    /// in one content array). Same draft → runtime promotion contract
    /// as `send(text:)`.
    func send(images: [(data: Data, mediaType: String)], caption: String? = nil) {
        let input = LocalUserInput(
            text: caption,
            images: images,
            planContent: nil
        )
        promoteOrForward(input: input) { runtime in
            runtime.send(images: images, caption: caption)
        }
    }

    private func promoteOrForward(
        input: LocalUserInput,
        forward: (SessionRuntime) -> Void
    ) {
        switch phase {
        case .draft(let draft):
            let (runtime, queuedEntry) = SessionRuntime.fromDraft(
                draft,
                cliClientFactory: cliClientFactory,
                initialInput: input
            )
            // Wire ALL sinks BEFORE kicking off bootstrap. `ensureStarted`
            // fires `onRecordPersisted` synchronously inside its persist
            // path; `failLaunch` fires `onLaunchFailure`; the queued
            // entry needs `onMessagesChange` for the bridge to render it.
            // Wiring last would race those events into the void.
            wireRuntimeMessagesSink(runtime)
            if let queuedEntry {
                runtime.onMessagesChange?(.appended(queuedEntry))
            }
            self.phase = .active(runtime)
            // Bootstrap kicks off NOW — sinks are attached, the queued
            // entry is in `runtime.messages` ready to be flushed by
            // `flushBootstrapBacklog` once the CLI hits `.idle`.
            runtime.ensureStarted()
            // Async LLM title-gen against the first user message. Until
            // it lands the row shows the first-message-derived title set
            // inside `fromDraft`; success overwrites the title and fires
            // `onRecordPersisted` so the sidebar re-reads `records`.
            if let firstText = input.text {
                runtime.generateTitle(from: firstText)
            }
            onPromoted?(runtime)
        case .active(let runtime):
            forward(runtime)
        }
    }

    // MARK: - Configuration writes

    /// Optimistic-write model setter. Routes to the draft setter while
    /// the session is still being configured; routes to the runtime
    /// (which also fires the CLI RPC) once active.
    func setModel(_ model: String) {
        switch phase {
        case .draft(let d): d.setModel(model)
        case .active(let r): r.setModel(model)
        }
    }

    func setEffort(_ effort: Effort) {
        switch phase {
        case .draft(let d): d.setEffort(effort)
        case .active(let r): r.setEffort(effort)
        }
    }

    func setPermissionMode(_ mode: PermissionMode) {
        switch phase {
        case .draft(let d): d.setPermissionMode(mode)
        case .active(let r): r.setPermissionMode(mode)
        }
    }

    func setFastMode(_ enabled: Bool) {
        switch phase {
        case .draft(let d): d.setFastMode(enabled)
        case .active(let r): r.setFastMode(enabled)
        }
    }

    func setAdditionalDirectories(_ dirs: [String]) {
        switch phase {
        case .draft(let d): d.setAdditionalDirectories(dirs)
        case .active(let r): r.setAdditionalDirectories(dirs)
        }
    }

    /// Presence flag — clears `hasUnread` on focus regardless of phase.
    func setFocused(_ focused: Bool) {
        switch phase {
        case .draft(let d): d.setFocused(focused)
        case .active(let r): r.setFocused(focused)
        }
    }

    /// Reply to a pending permission. Draft phase has no pending
    /// permissions; no-op.
    func respond(to permissionId: String, decision: PermissionDecision) {
        runtime?.respond(to: permissionId, decision: decision)
    }
}

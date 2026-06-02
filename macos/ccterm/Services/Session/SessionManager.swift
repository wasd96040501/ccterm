import Foundation
import Observation

/// `Session` registry. Lazily allocates and caches a `Session` façade
/// per `sessionId`. The façade internally toggles between
/// `.draft(SessionDraft)` and `.active(SessionRuntime)` — the manager
/// is one layer above and doesn't care which phase the session is in.
///
/// Holds its own `SessionRepository` instance: in production it's
/// `CoreDataSessionRepository` (sharing `CoreDataStack.shared` with the
/// legacy stack); unit tests can inject `InMemorySessionRepository`
/// (DEBUG only) to avoid touching the real CoreData store.
@Observable
@MainActor
final class SessionManager {

    /// Side effect performed when a worktree-backed session moves between
    /// archive and active state. Production wires
    /// `Self.defaultWorktreeArchive` / `defaultWorktreeRestore`, which
    /// shell out to git on a background queue. Tests inject a synchronous
    /// recorder so they can assert the call happened without standing up
    /// a real repo.
    typealias WorktreeSideEffect = @Sendable (SessionRecord) -> Void

    @ObservationIgnored private let repository: any SessionRepository
    /// CLI client factory injected at the manager level. Production wires
    /// `AgentSDKCLIClient.defaultFactory`; tests wire a `FakeCLIClient`
    /// factory once on the manager and every `Session` constructed by it
    /// inherits the injection — no per-session rewiring in test setups.
    @ObservationIgnored private let cliClientFactory: CLIClientFactory
    @ObservationIgnored private let worktreeArchive: WorktreeSideEffect
    @ObservationIgnored private let worktreeRestore: WorktreeSideEffect
    /// Cache of per-`sessionId` `Session` façades. **Observation-tracked**
    /// so views reading runtime-only state via `existingSession(_:)`
    /// (sidebar rows querying `isRunning` / `hasUnread`) get re-rendered
    /// when a session is first allocated. With `@ObservationIgnored`, the
    /// cold path — row body's first render sees `session == nil`, never
    /// subscribes, stays stale when the session later flips `isRunning`
    /// — silently breaks the indicator.
    private var sessions: [String: Session] = [:]

    /// Non-archived session records, descending by `lastActiveAt`. Sidebar
    /// v2 observes this array directly. Populated once at init and
    /// refreshed via `refreshRecords()`.
    private(set) var records: [SessionRecord] = []

    /// Archived records, descending by `archivedAt` then `lastActiveAt`.
    /// Lazily loaded — the Archive page calls `refreshArchivedRecords()`
    /// in `.task` so the cold path (user never opens the page) doesn't
    /// pay the extra fetch on app launch. `@Observable` so archive /
    /// unarchive triggered while the page is visible refreshes the list.
    private(set) var archivedRecords: [SessionRecord] = []

    /// Distinct folders represented in `archivedRecords`, keyed on
    /// `originPath` (so worktree sessions group with their parent repo).
    /// Refreshed in lock-step with `archivedRecords` so the Archive page's
    /// folder-filter popover always reads a derived value that matches the
    /// current row set — no view-side caching, no per-keystroke recompute,
    /// no observation-tracking trap.
    private(set) var archivedFolderOptions: [ArchivedFolder] = []

    /// Pushed when any handle reports a CLI launch failure. A single
    /// stable owner (`DetailRouterViewController`) installs this and
    /// presents the alert on the window.
    ///
    /// Push callback rather than an `@Observable` field on purpose: the
    /// old field was observed by every `ChatSessionViewController`
    /// through a re-arming `withObservationTracking` task that pinned the
    /// VC (strong `self` across the `await`). With N leaked VCs all
    /// observing, one launch failure stacked N alert sheets. One owner +
    /// one callback = one alert, no observation task, no retain cycle.
    @ObservationIgnored var onLaunchFailure: ((LaunchFailure) -> Void)?

    struct LaunchFailure: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let message: String
    }

    /// One option in the Archive page's folder-filter popover. `path` is
    /// the canonical identity (a `SessionRecord.originPath`); `name` is
    /// the leaf displayed as the row title. Two folders sharing the
    /// same leaf at different paths are distinct rows.
    struct ArchivedFolder: Identifiable, Hashable {
        let path: String
        let name: String
        var id: String { path }
    }

    /// Manager-level "turn ended on some session" sink. `AppState`
    /// wires this to `NotificationService.handleTurnEnded` at startup
    /// so every session the manager allocates gets the notification
    /// behavior for free — without `SessionRuntime` needing to know the
    /// notification service exists.
    @ObservationIgnored var onTurnEndedNotice: ((TurnEndedNotice) -> Void)?

    /// Manager-level "a session is asking for permission" sink. Wired by
    /// `AppState` to `NotificationService.handlePermissionPrompt` in the
    /// same place as `onTurnEndedNotice`, so every session the manager
    /// allocates gets permission banners for free without `SessionRuntime`
    /// knowing the notification service exists.
    @ObservationIgnored var onPermissionPromptNotice: ((PermissionPromptNotice) -> Void)?

    /// App-scope remote-launch coordinator, forwarded onto every `Session` it
    /// creates (design `remote-execution.md` §3g). nil in tests / when no
    /// remote-host store is wired — host-bound sessions then fail launch with a
    /// clear reason rather than silently running locally.
    @ObservationIgnored private let remoteLaunch: RemoteLaunchCoordinator?

    init(
        repository: any SessionRepository = CoreDataSessionRepository(),
        cliClientFactory: @escaping CLIClientFactory = AgentSDKCLIClient.defaultFactory,
        worktreeArchive: @escaping WorktreeSideEffect = SessionManager.defaultWorktreeArchive,
        worktreeRestore: @escaping WorktreeSideEffect = SessionManager.defaultWorktreeRestore,
        remoteLaunch: RemoteLaunchCoordinator? = nil
    ) {
        self.repository = repository
        self.cliClientFactory = cliClientFactory
        self.worktreeArchive = worktreeArchive
        self.worktreeRestore = worktreeRestore
        self.remoteLaunch = remoteLaunch
        self.records = repository.findAll()
    }

    /// macOS 26 SDK regression: a default class deinit on a `@MainActor`
    /// type routes through `swift_task_deinitOnExecutorImpl`, which the
    /// stricter Xcode 26 Concurrency runtime drives every time the
    /// last reference drops. `TaskLocal::StopLookupScope::~StopLookupScope`
    /// then frees an un-malloc'd pointer and libmalloc aborts
    /// (`___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED`).
    /// `nonisolated deinit` skips the executor-hop path. Symptom on
    /// CI's macos-26 runner: hosted XCTest crashed with SIGABRT when a
    /// test method's last `SessionManager` reference dropped at
    /// function return; local Darwin 25 didn't reproduce. Same fix
    /// `SessionRuntime`, `InMemorySessionRepository`, and
    /// `CoreDataSessionRepository` already use.
    nonisolated deinit {}

    /// Gracefully shut down every cached `Session` in parallel and only
    /// return after each one has actually exited (or its SDK-level
    /// timeout has fired SIGTERM). The app-quit path
    /// (`applicationShouldTerminate`) awaits this so total shutdown
    /// time is bounded by the slowest CLI, not by their sum — running
    /// N sessions serially would scale linearly with N.
    ///
    /// Snapshots the values up front so the iteration is stable even if
    /// a callback mutates the cache during shutdown. Sessions in
    /// `.draft` phase (no runtime) and runtimes in `.notStarted` /
    /// `.stopped` self-skip inside `closeAsync()`, so we don't need to
    /// pre-filter here.
    func shutdownAllAsync() async {
        let active = Array(sessions.values)
        guard !active.isEmpty else { return }
        appLog(.info, "SessionManager", "shutdownAllAsync count=\(active.count)")
        await withTaskGroup(of: Void.self) { group in
            for session in active {
                group.addTask { @MainActor in
                    await session.closeAsync()
                }
            }
        }
        appLog(.info, "SessionManager", "shutdownAllAsync done")
    }

    /// Get a `Session` for an existing record. Returns nil when the db
    /// has no matching record. First call creates and caches; subsequent
    /// calls return the same instance (stable identity). Read-only
    /// browsing — does not start a subprocess.
    func session(_ sessionId: String) -> Session? {
        if let session = sessions[sessionId] { return session }
        guard let record = repository.find(sessionId) else { return nil }
        let session = makeSession(from: record)
        wireSessionCallbacks(session)
        sessions[sessionId] = session
        return session
    }

    /// Build the right-phase `Session` for a persisted record: a
    /// `.draft`-status row (a `/new` / `/clear` draft that survived restart)
    /// rehydrates as a **draft-phase** façade so it routes to the landing
    /// page and promotes on first send; every other status is an `.active`
    /// runtime. Centralized so `session(_:)` and `prepareDraftSession(_:)`
    /// can't drift on this decision.
    private func makeSession(from record: SessionRecord) -> Session {
        let onPromoted: (SessionRuntime) -> Void = { [weak self] _ in self?.refreshRecords() }
        if record.status == .draft {
            return Session(
                draftRecord: record,
                repository: repository,
                cliClientFactory: cliClientFactory,
                onPromoted: onPromoted)
        }
        return Session(
            record: record,
            repository: repository,
            cliClientFactory: cliClientFactory,
            onPromoted: onPromoted)
    }

    /// Whether `sessionId` is a not-yet-sent draft. Prefers the cached
    /// façade's live phase (authoritative across the in-process
    /// `.draft → .active` promotion flip); falls back to the persisted
    /// `.draft` status for the uncached / cold-restart path, where the
    /// sidebar holds a row but no `Session` has been materialized yet. The
    /// detail router reads this to route to the landing page vs the
    /// transcript.
    func isDraftSession(_ sessionId: String) -> Bool {
        if let session = sessions[sessionId] { return session.isDraft }
        return repository.find(sessionId)?.status == .draft
    }

    /// Non-creating lookup. Returns the cached session if it exists,
    /// nil otherwise — never allocates. Sidebar rows use this to read
    /// runtime-only state (`isRunning` / `hasUnread`) without forcing
    /// every record in the history list to spin up a session.
    func existingSession(_ sessionId: String) -> Session? {
        sessions[sessionId]
    }

    /// Prepare a `Session` in `.draft` phase for a NewSession card. No
    /// repository read; the db row appears the first time the user
    /// sends a message and the underlying `SessionDraft` is promoted to
    /// a `SessionRuntime`. Idempotent get-or-create — re-entering New
    /// Session preserves the in-flight draft state.
    func prepareDraftSession(_ sessionId: String) -> Session {
        if let session = sessions[sessionId] { return session }
        let session: Session
        if let record = repository.find(sessionId) {
            // A record already exists for this id: a `.draft`-status row
            // (a `/new` / `/clear` draft, possibly restored from disk)
            // rehydrates as a draft-phase façade; any other status (the UI
            // navigated to an already-promoted session via the draft path)
            // starts in `.active` phase. `makeSession` owns this decision.
            session = makeSession(from: record)
        } else {
            session = Session(
                draftSessionId: sessionId,
                repository: repository,
                cliClientFactory: cliClientFactory,
                onPromoted: { [weak self] _ in self?.refreshRecords() })
        }
        wireSessionCallbacks(session)
        sessions[sessionId] = session
        return session
    }

    /// Create a fresh draft session for the `/new` / `/clear` builtins and
    /// surface it as an auto-focused sidebar row. The draft inherits
    /// `seededFrom`'s full configuration so the new session continues the one
    /// it was triggered from — cwd, originPath, worktree flag + source branch
    /// + **provisioned worktree branch**, model, effort, permission mode,
    /// additional + plugin directories, fast mode.
    ///
    /// The draft is persisted immediately as a `.draft`-status record (not an
    /// in-memory list), so it survives app restart and participates in the
    /// worktree reference count (see `archive`). The first send flips it
    /// `.draft → .pending` and promotes it exactly like the compose card.
    /// Returns the new draft's `sessionId`; the caller selects it, routing to
    /// the draft-landing page.
    ///
    /// **Worktree reuse.** For a worktree source we seed `cwd` from the
    /// source's *actual* worktree dir and carry `worktreeBranch`, so the new
    /// session continues in the **same** worktree (same branch, same
    /// uncommitted changes) rather than forking a fresh one. Because a
    /// persisted record already exists at first send, `ensureStarted`'s
    /// `fresh` check is false and the provisioning block is skipped — the CLI
    /// just launches in the seeded worktree dir. The worktree is torn down
    /// only when its last referencing session is archived (`archive`).
    ///
    /// `seededFrom` is resolved via `session(_:)` (not `existingSession`) so
    /// it materializes a façade even when the source is itself a draft
    /// (chained `/new`); a nil / unknown source just yields an unseeded
    /// draft (cwd stays nil → the landing bar shows the "pick a folder"
    /// state, same as a fresh New Session with no recents).
    func createSidebarDraft(seededFrom sourceId: String?) -> String {
        let newId = UUID().uuidString.lowercased()
        let draft = prepareDraftSession(newId)

        if let sourceId, let source = existingSession(sourceId) ?? session(sourceId),
            let target = draft.draft
        {
            // Config-forwarding reads on `Session` are phase-agnostic, so
            // this copies correctly whether the source is a live runtime or
            // another draft. Seed `cwd` from the source's actual cwd (for a
            // worktree source, its provisioned worktree dir) and carry
            // `worktreeBranch` so the new session adopts — and shares the
            // reference count of — the same worktree instead of forking one.
            if let cwd = source.cwd { target.setCwd(cwd) }
            target.setOriginPath(source.originPath)
            target.setWorktree(source.isWorktree)
            target.setSourceBranch(source.sourceBranch)
            target.setWorktreeBranch(source.worktreeBranch)
            target.setPluginDirectories(source.pluginDirectories)
            target.setAdditionalDirectories(source.additionalDirectories)
            target.setPermissionMode(source.permissionMode)
            target.setFastMode(source.fastModeEnabled)
            if let model = source.model { target.setModel(model) }
            if let effort = source.effort { target.setEffort(effort) }
        }

        // Persist a `.draft`-status row from the now-seeded config via the
        // same `toSessionRecord` path promotion uses (full `extra`, worktree
        // fields derived in one place; this also keeps `Effort.rawValue`'s
        // AgentSDK dependency inside `SessionConfig`, which imports it —
        // `SessionManager` does not). Empty title → rendered as "Untitled";
        // `createdAt`/`lastActiveAt` default to now so it sorts to the top of
        // its folder group. Saving eagerly is load-bearing: it's what makes
        // the row durable across restart and visible to the worktree refcount
        // when `/clear` archives the source moments later.
        let config = draft.draft?.config ?? SessionConfig()
        var record = config.toSessionRecord(sessionId: newId, title: "")
        record.status = .draft
        repository.save(record)
        refreshRecords()
        appLog(
            .info, "SessionManager",
            "createSidebarDraft sid=\(newId.prefix(8)) seededFrom=\(sourceId?.prefix(8).description ?? "(nil)") "
                + "cwd=\(draft.cwd ?? "(nil)") isWorktree=\(draft.isWorktree) "
                + "worktreeBranch=\(draft.worktreeBranch ?? "(nil)")")
        return newId
    }

    /// Wire the session's manager-facing callbacks. Called once per
    /// `Session` on creation.
    ///
    /// - `onLaunchFailure` → forwards to the manager-level
    ///   `onLaunchFailure` push callback so a single owner surfaces CLI
    ///   launch errors.
    /// - `onRecordPersisted` → `refreshRecords()` so the sidebar picks
    ///   up sessions whose db row is saved asynchronously (worktree-
    ///   provisioning collision-recovery patch fires this from inside
    ///   the worktree-provision continuation, well after the initial
    ///   `onPromoted` callback).
    ///
    /// The promotion-time `refreshRecords()` hook is injected through
    /// `Session.init(onPromoted:)` (and fires exactly once, at the
    /// draft → active phase flip).
    private func wireSessionCallbacks(_ session: Session) {
        let sid = session.sessionId
        // Forward the app-scope remote-launch coordinator before the session can
        // start (UI calls activate()/send() only after this returns).
        session.remoteLaunch = remoteLaunch
        session.onLaunchFailure = { [weak self] reason in
            // `reason` is the raw description the runtime already produced;
            // no localization or field reshuffle here.
            self?.onLaunchFailure?(LaunchFailure(sessionId: sid, message: reason))
        }
        session.onRecordPersisted = { [weak self] in
            appLog(
                .info, "SessionManager",
                "onRecordPersisted fired sid=\(sid.prefix(8)) — refreshing records")
            self?.refreshRecords()
        }
        session.onTurnEnded = { [weak self] notice in
            self?.onTurnEndedNotice?(notice)
        }
        session.onPermissionPrompt = { [weak self] notice in
            self?.onPermissionPromptNotice?(notice)
        }
    }

    /// Re-read every record from the repository and write back to
    /// `records`. The caller triggers this after a NewSession launches, after
    /// a `/new` / `/clear` draft is persisted, and at every promotion. A
    /// `/new` / `/clear` draft is an ordinary `.draft`-status row here, so its
    /// promotion is an in-place status flip on the same row (`.draft` →
    /// `.pending` → `.created`) — no draft-row-to-real-row swap.
    func refreshRecords() {
        records = repository.findAll()
    }

    /// Re-read the archived list from the repository. Called by the
    /// Archive page on appear and after any archive/unarchive operation
    /// that mutates archived state. The derived `archivedFolderOptions`
    /// list is refreshed in the same call so observers see a consistent
    /// pair.
    func refreshArchivedRecords() {
        let fresh = repository.findArchived()
        archivedRecords = fresh
        archivedFolderOptions = Self.deriveFolderOptions(from: fresh)
    }

    /// Async variant used by the Archive page's first paint so the
    /// CoreData fetch lands on a background context instead of blocking
    /// the main thread. In-memory test repos fall back to the
    /// synchronous read after a single `Task.yield()` — they're instant
    /// but the yield still gives SwiftUI a frame to render the page
    /// chrome before the records appear. The folder-options derivation
    /// runs on the same hop so the Archive page sees both updates land
    /// atomically.
    func refreshArchivedRecordsAsync() async {
        let fresh: [SessionRecord]
        if let coreDataRepo = repository as? CoreDataSessionRepository {
            fresh = await coreDataRepo.findArchivedAsync()
        } else {
            await Task.yield()
            fresh = repository.findArchived()
        }
        archivedRecords = fresh
        archivedFolderOptions = Self.deriveFolderOptions(from: fresh)
    }

    /// Group `records` by `originPath` and produce a sorted, deduped
    /// `[ArchivedFolder]` for the Archive page's folder-filter popover.
    /// Records without an `originPath` are silently dropped — they can't
    /// be filtered into a single bucket. Sorted alphabetically by leaf
    /// name for predictable scanning.
    static func deriveFolderOptions(from records: [SessionRecord]) -> [ArchivedFolder] {
        let buckets = Dictionary(grouping: records) { $0.originPath }
        return buckets.compactMap { path, _ -> ArchivedFolder? in
            guard let path, !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return ArchivedFolder(path: path, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Soft-delete: flip the record to `.archived` so it drops out of
    /// `records` / sidebar, while remaining recoverable from the Archive
    /// page. If the session has a live handle, stop the CLI subprocess
    /// first and drop the cached instance — a later unarchive lands on
    /// a fresh handle.
    ///
    /// For worktree-backed sessions the on-disk worktree directory is
    /// also removed (via the injected `worktreeArchive` closure) — but only
    /// when no other live session still references the same worktree (see
    /// `liveWorktreeReferenceExists`). The DB record keeps `cwd` /
    /// `originPath` / `worktreeBranch` so `unarchive` has everything it needs
    /// to reconstruct the worktree.
    ///
    /// A never-sent `.draft` row is **hard-deleted** instead of soft-archived
    /// (it has no conversation worth keeping and shouldn't surface on the
    /// Archive page) — this preserves the old "dismiss an unsent draft → it
    /// vanishes" behavior. Either way the worktree teardown runs through the
    /// same reference-count gate.
    func archive(_ sessionId: String) {
        // Snapshot the record BEFORE mutating the repo, because
        // `repository.archive` is the only way to flip status; we need
        // the live record's worktree fields to drive the side effect.
        let snapshot = repository.find(sessionId)
        sessions[sessionId]?.stop()
        sessions.removeValue(forKey: sessionId)
        if snapshot?.status == .draft {
            repository.delete(sessionId)
        } else {
            repository.archive(sessionId)
        }
        refreshRecords()
        refreshArchivedRecords()
        // Evaluate the reference count AFTER the repo mutation so the
        // just-archived/deleted self-row is already out of `findAll()`. Tear
        // the worktree down only when this was its last live referencer;
        // otherwise a co-owner (e.g. the session a `/new` adopter shares with,
        // or the `/clear` adopter holding the source's worktree) keeps it.
        if let snapshot, snapshot.isWorktree,
            !liveWorktreeReferenceExists(
                branch: snapshot.worktreeBranch, cwd: snapshot.cwd, excluding: sessionId)
        {
            worktreeArchive(snapshot)
        }
    }

    /// Whether any other **non-archived** session still points at the worktree
    /// identified by `branch` / `cwd`. The records table IS the reference
    /// count — `findAll()` excludes archived rows (and the just-removed self
    /// row), and includes persisted `.draft` adopters, so this is durable
    /// across app restart with no separate store. Matches on `worktreeBranch`
    /// **or** `cwd`: `invokeWorktreeArchiveSync` derives the dir to remove
    /// from `cwd.lastPathComponent`, so a shared cwd must also block deletion
    /// even if a row's branch is nil.
    private func liveWorktreeReferenceExists(
        branch: String?, cwd: String?, excluding sessionId: String
    ) -> Bool {
        repository.findAll().contains { other in
            guard other.sessionId != sessionId, other.isWorktree else { return false }
            if let branch, other.worktreeBranch == branch { return true }
            if let cwd, other.cwd == cwd { return true }
            return false
        }
    }

    /// Bring an archived record back: flip status to `.created`, clear
    /// `archivedAt`, and (for worktree-backed sessions) restore the
    /// on-disk worktree via `Worktree.restore` so the next `activate`
    /// can chdir into a real directory. Restore runs through the
    /// injected `worktreeRestore` closure (background-dispatched in
    /// production, synchronous in tests).
    ///
    /// Worktree restore is best-effort: if the source branch was
    /// already deleted (the user manually `git branch -D`'d it), the
    /// record still flips to `.created` — the user will see the
    /// "cwd missing" error on the next `activate` and can re-create
    /// the worktree from there. We deliberately do NOT block the
    /// record-state flip on git success, because that would leave the
    /// row in a weird "halfway back" state that's worse than a
    /// recoverable error.
    func unarchive(_ sessionId: String) {
        let snapshot = repository.find(sessionId)
        // Defensive: any stale session from before archive should be
        // dropped so the next view-mount creates a fresh one against
        // the now-flipped record. In practice `archive` already does
        // this; the duplicate clear costs nothing.
        sessions[sessionId]?.stop()
        sessions.removeValue(forKey: sessionId)
        repository.unarchive(sessionId)
        refreshRecords()
        refreshArchivedRecords()
        if let snapshot, snapshot.isWorktree {
            worktreeRestore(snapshot)
        }
    }
}

// MARK: - Default worktree side effects

extension SessionManager {

    /// Background-dispatched `Worktree.remove` for the production
    /// `worktreeArchive` injection. `git worktree remove` typically
    /// completes in <2s but can block on filesystem operations, so we
    /// dispatch to `userInitiated` rather than running on the main
    /// actor where it would freeze the UI.
    ///
    /// `nonisolated` so the static-let initializer runs at module load
    /// without going through a `MainActor` hop. The closure body itself
    /// dispatches off-main; only the closure value lives here.
    nonisolated static let defaultWorktreeArchive: WorktreeSideEffect = { record in
        DispatchQueue.global(qos: .userInitiated).async {
            invokeWorktreeArchiveSync(for: record)
        }
    }

    /// Background-dispatched `Worktree.restore` for the production
    /// `worktreeRestore` injection. `git worktree add` can take seconds
    /// (especially when LFS smudge or hook copy kicks in); off-main
    /// dispatch keeps the UI responsive while the restore runs.
    nonisolated static let defaultWorktreeRestore: WorktreeSideEffect = { record in
        DispatchQueue.global(qos: .userInitiated).async {
            invokeWorktreeRestoreSync(for: record)
        }
    }

    /// Construct the `Worktree` value object the persisted record points
    /// at and call `remove()`. Worktree-path / name derivation mirrors
    /// `Worktree.locate` but works from the DB row alone (no on-disk
    /// state) — by the time archive runs the user has already accepted
    /// that the worktree will be torn down.
    ///
    /// `internal` rather than `private` so the integration test
    /// (`SessionManagerArchiveWorktreeTests`) can drive the same git
    /// commands the production background path runs, on the test
    /// thread, and assert disk state synchronously.
    ///
    /// `nonisolated` because git / filesystem work doesn't touch any
    /// `MainActor` state; the production default closure dispatches
    /// onto `DispatchQueue.global(qos: .userInitiated)` and would
    /// otherwise force a hop back to the main actor.
    nonisolated static func invokeWorktreeArchiveSync(for record: SessionRecord) {
        guard
            let cwd = record.cwd,
            let origin = record.originPath
        else {
            appLog(
                .warning, "SessionManager",
                "worktree archive skipped — missing cwd/originPath sid=\(record.sessionId.prefix(8))")
            return
        }
        let baseRepo = Worktree.resolveBaseRepo(origin)
        let name = (cwd as NSString).lastPathComponent
        let wt = Worktree(path: cwd, name: name, baseRepo: baseRepo, sourceBranch: nil)
        do {
            try wt.remove()
        } catch {
            appLog(
                .warning, "SessionManager",
                "worktree.remove failed sid=\(record.sessionId.prefix(8)) err=\(error.localizedDescription)")
        }
    }

    /// `git worktree add <path> <branch>` to rebuild the directory the
    /// archive teardown removed. The branch was preserved on archive
    /// (only the worktree dir was deleted), so add-with-existing-branch
    /// is the correct semantic.
    ///
    /// `internal` so the integration test can drive it on-thread; see
    /// the matching note on `invokeWorktreeArchiveSync(for:)`.
    nonisolated static func invokeWorktreeRestoreSync(for record: SessionRecord) {
        guard
            let cwd = record.cwd,
            let origin = record.originPath,
            let branch = record.worktreeBranch
        else {
            appLog(
                .warning, "SessionManager",
                "worktree unarchive skipped — missing cwd/origin/branch sid=\(record.sessionId.prefix(8))")
            return
        }
        let baseRepo = Worktree.resolveBaseRepo(origin)
        if Worktree.restore(at: cwd, baseRepo: baseRepo, branch: branch) == nil {
            appLog(
                .warning, "SessionManager",
                "Worktree.restore failed sid=\(record.sessionId.prefix(8)) branch=\(branch)")
        }
    }
}

import Foundation
import Observation

/// `SessionHandle2` registry (v2 stack). Currently carries only the minimal
/// responsibility for "read-only history browsing": lazily create and cache
/// a `SessionHandle2` per `sessionId`. Does not handle launch / stop /
/// archive / pin — those still live on the legacy `SessionService` and v2
/// takes them over incrementally.
///
/// Holds its own `SessionRepository` instance: in production it's
/// `CoreDataSessionRepository` (sharing `CoreDataStack.shared` with the
/// legacy stack); unit tests can inject `InMemorySessionRepository`
/// (DEBUG only) to avoid touching the real CoreData store.
@Observable
@MainActor
final class SessionManager2 {

    @ObservationIgnored private let repository: any SessionRepository
    @ObservationIgnored private var handles: [String: SessionHandle2] = [:]

    /// Non-archived session records, descending by `lastActiveAt`. Sidebar
    /// v2 observes this array directly. Populated once at init and
    /// refreshed via `refreshRecords()`.
    private(set) var records: [SessionRecord] = []

    /// Most recent CLI launch failure from any handle. RootView2 binds to
    /// this field with `.alert`: non-nil triggers the alert, and confirming
    /// calls `clearLaunchFailure()` to reset. New failures overwrite old
    /// ones — concurrent failures only keep the latest (no use case needs
    /// the full list).
    private(set) var lastLaunchFailure: LaunchFailure?

    struct LaunchFailure: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let message: String
    }

    init(repository: any SessionRepository = CoreDataSessionRepository()) {
        self.repository = repository
        self.records = repository.findAll()
    }

    func clearLaunchFailure() {
        lastLaunchFailure = nil
    }

    /// Get a `SessionHandle2` by `sessionId`. Returns nil when the db has
    /// no matching record. First call creates and caches; subsequent calls
    /// return the same instance (stable identity). Read-only browsing —
    /// does not start a subprocess.
    func session(_ sessionId: String) -> SessionHandle2? {
        if let handle = handles[sessionId] { return handle }
        guard repository.find(sessionId) != nil else { return nil }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        wireHandleCallbacks(handle)
        handles[sessionId] = handle
        return handle
    }

    /// Non-creating lookup. Returns the cached handle if it exists,
    /// nil otherwise — never allocates. Sidebar rows use this to read
    /// runtime-only state (`isRunning` / `hasUnread`) without forcing
    /// every record in the history list to spin up a handle.
    func existingHandle(_ sessionId: String) -> SessionHandle2? {
        handles[sessionId]
    }

    /// Prepare a handle for a NewSession draft. The db must have **no**
    /// matching record (identity comes from a fresh UI-generated UUID).
    /// Differs from `session(_:)`: no repository read, pure in-memory
    /// construction; the eventual `activate()` / `send(_:)` triggers
    /// `ensureStarted`'s fresh path which writes the db.
    func prepareDraft(_ sessionId: String) -> SessionHandle2 {
        if let handle = handles[sessionId] { return handle }
        let handle = SessionHandle2(sessionId: sessionId, repository: repository)
        wireHandleCallbacks(handle)
        handles[sessionId] = handle
        return handle
    }

    /// Wire the handle's manager-facing callbacks. Called once per handle
    /// on creation:
    ///
    /// - `onLaunchFailure` → `lastLaunchFailure` so RootView2's `.alert`
    ///   surfaces CLI launch errors.
    /// - `onRecordPersisted` → `refreshRecords()` so the sidebar picks up
    ///   sessions whose db row is saved asynchronously (worktree-
    ///   provisioning path; see comment on the handle's property).
    private func wireHandleCallbacks(_ handle: SessionHandle2) {
        let sid = handle.sessionId
        handle.onLaunchFailure = { [weak self] reason in
            // `reason` is the raw description the handle already produced;
            // no localization or field reshuffle here.
            self?.lastLaunchFailure = LaunchFailure(
                sessionId: sid,
                message: reason
            )
        }
        handle.onRecordPersisted = { [weak self] in
            appLog(
                .info, "SessionManager2",
                "onRecordPersisted fired sid=\(sid.prefix(8)) — refreshing records")
            self?.refreshRecords()
        }
    }

    /// Re-read every record from the repository and write back to
    /// `records`. The caller triggers this after a NewSession launches.
    func refreshRecords() {
        records = repository.findAll()
    }

    /// Soft-delete: flip the record to `.archived` so it drops out of
    /// `records` / sidebar, while remaining recoverable from the future
    /// archive list page. If the session has a live handle, stop the CLI
    /// subprocess first and drop the cached instance — a later
    /// unarchive lands on a fresh handle.
    func archive(_ sessionId: String) {
        handles[sessionId]?.stop()
        handles.removeValue(forKey: sessionId)
        repository.archive(sessionId)
        refreshRecords()
    }
}

import CoreData
import Foundation

// MARK: - SessionExtraUpdate

/// Partial update for `SessionRecord.extra`. Only non-nil fields are
/// applied.
struct SessionExtraUpdate {
    var pluginDirs: [String]?
    var permissionMode: String?
    var addDirs: [String]?
    var model: String?
    var effort: String?
}

// MARK: - SessionRepository

/// DAO contract for the `SessionRecord` entity.
///
/// Production implementation is `CoreDataSessionRepository`, backed by
/// `CDSessionRecord` / CoreData. Unit tests use `InMemorySessionRepository`
/// (DEBUG only) to avoid contaminating the main CoreData store.
///
/// SessionRecord is a persisted entity describing "one session record" —
/// id, cwd, status, timestamps, etc. **It does not contain runtime state**
/// (messages, process state); that lives on `SessionHandle2`.
protocol SessionRepository: AnyObject {

    // MARK: Query

    /// Look up by sessionId; nil when missing.
    func find(_ sessionId: String) -> SessionRecord?

    /// All non-archived sessions, descending by lastActiveAt.
    func findAll() -> [SessionRecord]

    /// All archived sessions.
    func findArchived() -> [SessionRecord]

    // MARK: Create / Delete

    /// Persist a SessionRecord. Overwrites on id conflict.
    func save(_ session: SessionRecord)

    /// Archive: status → .archived, archivedAt = now.
    func archive(_ sessionId: String)

    /// Unarchive: status → .created, clear archivedAt.
    func unarchive(_ sessionId: String)

    /// Permanently delete from storage. Unrecoverable.
    func delete(_ sessionId: String)

    // MARK: Update

    /// Update the persisted lifecycle state.
    func updateStatus(_ sessionId: String, to status: SessionStatus)

    /// Update cwd and clear error.
    func updateCwd(_ sessionId: String, cwd: String)

    /// Update title.
    func updateTitle(_ sessionId: String, title: String)

    /// Write stderr / process-exit reason on launch failure. Pass nil to clear.
    func updateError(_ sessionId: String, error: String?)

    /// Partial update of extra fields; only non-nil fields in
    /// SessionExtraUpdate are applied.
    func updateExtra(_ sessionId: String, with update: SessionExtraUpdate)

    /// Update worktree branch name. Saved on archive so unarchive can
    /// rebuild the worktree.
    func updateWorktreeBranch(_ sessionId: String, branch: String?)

    /// Update isWorktree flag. Called by SessionHandle while non-active only.
    func updateIsWorktree(_ sessionId: String, isWorktree: Bool)

    /// Pin a session.
    func pinSession(sessionId: String)

    /// Unpin a session.
    func unpinSession(sessionId: String)

    /// Refresh lastActiveAt to now. Call on every interaction.
    func touch(_ sessionId: String)
}

// MARK: - CoreDataSessionRepository

/// CoreData implementation of `SessionRepository`. Backed by
/// `CDSessionRecord`; shares `CoreDataStack.shared` with the legacy stack.
final class CoreDataSessionRepository: SessionRepository {

    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Workaround: macOS 26 SDK's `swift_task_deinitOnExecutorImpl` hits a
    /// libmalloc pointer-freed-but-not-allocated crash in the isolated
    /// deinit chain. Explicit nonisolated deinit skips the executor-hop
    /// path. See SessionHandle2.swift for the matching note.
    nonisolated deinit {}

    // MARK: - Query

    func find(_ sessionId: String) -> SessionRecord? {
        guard let entity = fetchEntity(sessionId) else { return nil }
        return Self.session(from: entity)
    }

    func findAll() -> [SessionRecord] {
        let request = NSFetchRequest<CDSessionRecord>(entityName: "CDSessionRecord")
        request.predicate = NSPredicate(format: "status != %@", SessionStatus.archived.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "lastActiveAt", ascending: false)]
        do {
            let results = try coreDataStack.viewContext.fetch(request)
            return results.compactMap { Self.session(from: $0) }
        } catch {
            appLog(.error, "CoreDataSessionRepository", "findAll failed: \(error.localizedDescription)")
            return []
        }
    }

    func findArchived() -> [SessionRecord] {
        let request = NSFetchRequest<CDSessionRecord>(entityName: "CDSessionRecord")
        request.predicate = NSPredicate(format: "status == %@", SessionStatus.archived.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "lastActiveAt", ascending: false)]
        do {
            let results = try coreDataStack.viewContext.fetch(request)
            return results.compactMap { Self.session(from: $0) }
        } catch {
            appLog(.error, "CoreDataSessionRepository", "findArchived failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Create / Delete

    func save(_ session: SessionRecord) {
        let context = coreDataStack.viewContext
        let entity = fetchEntity(session.sessionId) ?? CDSessionRecord(context: context)

        entity.uuid = session.id
        entity.sessionId = session.sessionId
        entity.title = session.title
        entity.cwd = session.cwd
        entity.createdAt = session.createdAt
        entity.lastActiveAt = session.lastActiveAt
        entity.status = session.status.rawValue
        entity.archivedAt = session.archivedAt
        entity.isWorktree = session.isWorktree
        entity.originPath = session.originPath
        entity.extraJSON = Self.encodeExtra(session.extra)
        entity.error = session.error
        entity.isPinned = session.isPinned
        entity.pinnedAt = session.pinnedAt
        entity.isTempDir = session.isTempDir
        entity.worktreeBranch = session.worktreeBranch

        coreDataStack.saveContext()
    }

    func archive(_ sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.status = SessionStatus.archived.rawValue
        entity.archivedAt = Date()
        coreDataStack.saveContext()
    }

    func unarchive(_ sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.status = SessionStatus.created.rawValue
        entity.archivedAt = nil
        coreDataStack.saveContext()
    }

    func delete(_ sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        coreDataStack.viewContext.delete(entity)
        coreDataStack.saveContext()
    }

    // MARK: - Update

    func updateStatus(_ sessionId: String, to status: SessionStatus) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.status = status.rawValue
        if status == .created {
            entity.lastActiveAt = Date()
        }
        coreDataStack.saveContext()
    }

    func updateCwd(_ sessionId: String, cwd: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.cwd = cwd
        entity.error = nil
        coreDataStack.saveContext()
    }

    func updateTitle(_ sessionId: String, title: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.title = title
        coreDataStack.saveContext()
    }

    func updateError(_ sessionId: String, error: String?) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.error = error
        coreDataStack.saveContext()
    }

    func updateExtra(_ sessionId: String, with update: SessionExtraUpdate) {
        guard let entity = fetchEntity(sessionId) else { return }
        var extra = Self.decodeExtra(entity.extraJSON)
        if let pluginDirs = update.pluginDirs {
            extra.pluginDirs = pluginDirs
        }
        if let permissionMode = update.permissionMode {
            extra.permissionMode = permissionMode
        }
        if let addDirs = update.addDirs {
            extra.addDirs = addDirs
        }
        if let model = update.model {
            extra.model = model
        }
        if let effort = update.effort {
            extra.effort = effort
        }
        entity.extraJSON = Self.encodeExtra(extra)
        coreDataStack.saveContext()
    }

    func updateWorktreeBranch(_ sessionId: String, branch: String?) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.worktreeBranch = branch
        coreDataStack.saveContext()
    }

    func updateIsWorktree(_ sessionId: String, isWorktree: Bool) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.isWorktree = isWorktree
        coreDataStack.saveContext()
    }

    func pinSession(sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.isPinned = true
        entity.pinnedAt = Date()
        coreDataStack.saveContext()
    }

    func unpinSession(sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.isPinned = false
        entity.pinnedAt = nil
        coreDataStack.saveContext()
    }

    func touch(_ sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.lastActiveAt = Date()
        coreDataStack.saveContext()
    }

    // MARK: - Private

    private func fetchEntity(_ sessionId: String) -> CDSessionRecord? {
        let request = NSFetchRequest<CDSessionRecord>(entityName: "CDSessionRecord")
        request.predicate = NSPredicate(format: "sessionId == %@", sessionId)
        request.fetchLimit = 1
        return (try? coreDataStack.viewContext.fetch(request))?.first
    }

    private static func session(from entity: CDSessionRecord) -> SessionRecord? {
        guard let uuid = entity.uuid,
            let sessionId = entity.sessionId,
            let createdAt = entity.createdAt,
            let lastActiveAt = entity.lastActiveAt
        else {
            return nil
        }
        let status: SessionStatus
        if let rawStatus = entity.status, let parsed = SessionStatus(rawValue: rawStatus) {
            status = parsed
        } else {
            status = .pending
        }
        return SessionRecord(
            id: uuid,
            sessionId: sessionId,
            title: entity.title ?? "[unknown session]",
            cwd: entity.cwd,
            isWorktree: entity.isWorktree,
            originPath: entity.originPath,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            status: status,
            archivedAt: entity.archivedAt,
            extra: decodeExtra(entity.extraJSON),
            error: entity.error,
            isPinned: entity.isPinned,
            pinnedAt: entity.pinnedAt,
            isTempDir: entity.isTempDir,
            worktreeBranch: entity.worktreeBranch
        )
    }

    private static func encodeExtra(_ extra: SessionExtra) -> String? {
        guard let data = try? JSONEncoder().encode(extra) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeExtra(_ json: String?) -> SessionExtra {
        guard let json, let data = json.data(using: .utf8),
            let extra = try? JSONDecoder().decode(SessionExtra.self, from: data)
        else {
            return SessionExtra()
        }
        return extra
    }
}

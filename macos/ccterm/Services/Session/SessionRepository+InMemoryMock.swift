#if DEBUG

import Foundation

/// In-memory implementation of `SessionRepository`.
///
/// **DEBUG build only.** Unit tests inject this so they can drive a
/// `SessionManager2` / `SessionHandle2` without touching the on-disk
/// CoreData store (`CDSessionRecord`). Lifetime is tied to a single
/// process; everything is wiped on exit, no persistent side effects.
///
/// Behavior contract matches `CoreDataSessionRepository`, so swapping does
/// not require branching in `SessionManager2` / `SessionHandle2`.
///
/// Not thread-safe; callers (mostly `@MainActor` `SessionHandle2` /
/// `SessionManager2`) use it on the main thread.
final class InMemorySessionRepository: SessionRepository {

    private var records: [String: SessionRecord] = [:]

    init() {}

    // MARK: - Query

    func find(_ sessionId: String) -> SessionRecord? {
        records[sessionId]
    }

    func findAll() -> [SessionRecord] {
        records.values
            .filter { $0.status != .archived }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    func findArchived() -> [SessionRecord] {
        records.values
            .filter { $0.status == .archived }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    // MARK: - Create / Delete

    func save(_ session: SessionRecord) {
        records[session.sessionId] = session
    }

    func archive(_ sessionId: String) {
        guard var record = records[sessionId] else { return }
        record.status = .archived
        record.archivedAt = Date()
        records[sessionId] = record
    }

    func unarchive(_ sessionId: String) {
        guard var record = records[sessionId] else { return }
        record.status = .created
        record.archivedAt = nil
        records[sessionId] = record
    }

    func delete(_ sessionId: String) {
        records.removeValue(forKey: sessionId)
    }

    // MARK: - Update

    func updateStatus(_ sessionId: String, to status: SessionStatus) {
        guard var record = records[sessionId] else { return }
        record.status = status
        if status == .created {
            record.lastActiveAt = Date()
        }
        records[sessionId] = record
    }

    func updateCwd(_ sessionId: String, cwd: String) {
        guard var record = records[sessionId] else { return }
        record.cwd = cwd
        record.error = nil
        records[sessionId] = record
    }

    func updateTitle(_ sessionId: String, title: String) {
        guard var record = records[sessionId] else { return }
        record.title = title
        records[sessionId] = record
    }

    func updateError(_ sessionId: String, error: String?) {
        guard var record = records[sessionId] else { return }
        record.error = error
        records[sessionId] = record
    }

    func updateExtra(_ sessionId: String, with update: SessionExtraUpdate) {
        guard var record = records[sessionId] else { return }
        if let pluginDirs = update.pluginDirs { record.extra.pluginDirs = pluginDirs }
        if let permissionMode = update.permissionMode { record.extra.permissionMode = permissionMode }
        if let addDirs = update.addDirs { record.extra.addDirs = addDirs }
        if let model = update.model { record.extra.model = model }
        if let effort = update.effort { record.extra.effort = effort }
        records[sessionId] = record
    }

    func updateWorktreeBranch(_ sessionId: String, branch: String?) {
        guard var record = records[sessionId] else { return }
        record.worktreeBranch = branch
        records[sessionId] = record
    }

    func updateIsWorktree(_ sessionId: String, isWorktree: Bool) {
        guard var record = records[sessionId] else { return }
        record.isWorktree = isWorktree
        records[sessionId] = record
    }

    func pinSession(sessionId: String) {
        guard var record = records[sessionId] else { return }
        record.isPinned = true
        record.pinnedAt = Date()
        records[sessionId] = record
    }

    func unpinSession(sessionId: String) {
        guard var record = records[sessionId] else { return }
        record.isPinned = false
        record.pinnedAt = nil
        records[sessionId] = record
    }

    func touch(_ sessionId: String) {
        guard var record = records[sessionId] else { return }
        record.lastActiveAt = Date()
        records[sessionId] = record
    }
}

#endif

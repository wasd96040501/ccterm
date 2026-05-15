#if DEBUG

import Foundation

/// `SessionRepository` 的纯内存实现。
///
/// **仅 DEBUG build**。UI test 用此实现避免污染主 CoreData store(`CDSessionRecord`)
/// 形成脏数据。生命周期与单次 app 进程绑定:进程退出即清空,无任何持久化副作用。
///
/// 行为契约与 `CoreDataSessionRepository` 一致——保证 swap 后 `SessionManager2` /
/// `SessionHandle2` 不需要分支处理。
///
/// 不是 thread-safe;调用方(主体是 `@MainActor` 的 `SessionHandle2` / `SessionManager2`)
/// 在主线程使用。
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

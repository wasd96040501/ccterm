import Foundation
import CoreData

// MARK: - SessionExtraUpdate

/// SessionRecord extra 字段的部分更新。只更新非 nil 字段。
struct SessionExtraUpdate {
    var pluginDirs: [String]?
    var permissionMode: String?
    var addDirs: [String]?
    var model: String?
    var effort: String?
}

// MARK: - SessionRepository

/// SessionRecord 实体的持久化层（DAO）。基于 CoreData（CDSessionRecord）。
///
/// 由 SessionService 内部持有，外层不直接使用。
/// SessionRecord 是持久化实体，描述"一条会话记录"——id、cwd、status、时间戳等。
/// 不含运行时状态（消息、进程状态）。运行时状态由 SessionHandle 持有。
///
/// 关系：SessionRepository 1 <--管理--* SessionRecord（CDSessionRecord）
class SessionRepository {

    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Workaround: macOS 26 SDK 的 `swift_task_deinitOnExecutorImpl` 在 isolated deinit 链中
    /// 命中 libmalloc pointer-freed-but-not-allocated 崩溃。显式 nonisolated deinit 跳过
    /// executor-hop 路径。详见 SessionHandle2.swift 的同类注释。
    nonisolated deinit { }

    // MARK: - Query

    /// 按 sessionId 查找。未找到返回 nil。
    func find(_ sessionId: String) -> SessionRecord? {
        guard let entity = fetchEntity(sessionId) else { return nil }
        return Self.session(from: entity)
    }

    /// 查找所有非 archived 的会话，按 lastActiveAt 降序。
    func findAll() -> [SessionRecord] {
        let request = NSFetchRequest<CDSessionRecord>(entityName: "CDSessionRecord")
        request.predicate = NSPredicate(format: "status != %@", SessionStatus.archived.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "lastActiveAt", ascending: false)]
        do {
            let results = try coreDataStack.viewContext.fetch(request)
            return results.compactMap { Self.session(from: $0) }
        } catch {
            appLog(.error, "SessionRepository", "findAll failed: \(error.localizedDescription)")
            return []
        }
    }

    /// 查找所有 archived 的会话。
    func findArchived() -> [SessionRecord] {
        let request = NSFetchRequest<CDSessionRecord>(entityName: "CDSessionRecord")
        request.predicate = NSPredicate(format: "status == %@", SessionStatus.archived.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "lastActiveAt", ascending: false)]
        do {
            let results = try coreDataStack.viewContext.fetch(request)
            return results.compactMap { Self.session(from: $0) }
        } catch {
            appLog(.error, "SessionRepository", "findArchived failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Create / Delete

    /// 持久化一个新的 SessionRecord。id 冲突时覆盖。
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

    /// 归档会话。status → .archived，archivedAt = now。
    func archive(_ sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.status = SessionStatus.archived.rawValue
        entity.archivedAt = Date()
        coreDataStack.saveContext()
    }

    /// 取消归档。status → .created，清除 archivedAt。
    func unarchive(_ sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.status = SessionStatus.created.rawValue
        entity.archivedAt = nil
        coreDataStack.saveContext()
    }

    /// 从存储中永久删除。不可恢复。
    func delete(_ sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        coreDataStack.viewContext.delete(entity)
        coreDataStack.saveContext()
    }

    // MARK: - Update

    /// 更新会话的持久化生命周期状态。
    func updateStatus(_ sessionId: String, to status: SessionStatus) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.status = status.rawValue
        if status == .created {
            entity.lastActiveAt = Date()
        }
        coreDataStack.saveContext()
    }

    /// 更新会话的 cwd。同时清除 error。
    func updateCwd(_ sessionId: String, cwd: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.cwd = cwd
        entity.error = nil
        coreDataStack.saveContext()
    }

    /// 更新会话标题。
    func updateTitle(_ sessionId: String, title: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.title = title
        coreDataStack.saveContext()
    }

    /// 启动失败时写 stderr。
    func updateError(_ sessionId: String, error: String?) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.error = error
        coreDataStack.saveContext()
    }

    /// 部分更新 extra 字段。只更新 SessionExtraUpdate 中非 nil 的字段。
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

    /// 更新 worktree 分支名。归档时保存，用于取消归档时重建 worktree。
    func updateWorktreeBranch(_ sessionId: String, branch: String?) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.worktreeBranch = branch
        coreDataStack.saveContext()
    }

    /// 更新 isWorktree 开关。仅 non-active 下由 SessionHandle 调用。
    func updateIsWorktree(_ sessionId: String, isWorktree: Bool) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.isWorktree = isWorktree
        coreDataStack.saveContext()
    }

    /// 置顶会话。
    func pinSession(sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.isPinned = true
        entity.pinnedAt = Date()
        coreDataStack.saveContext()
    }

    /// 取消置顶。
    func unpinSession(sessionId: String) {
        guard let entity = fetchEntity(sessionId) else { return }
        entity.isPinned = false
        entity.pinnedAt = nil
        coreDataStack.saveContext()
    }

    /// 刷新 lastActiveAt 为当前时间。每次会话有交互时调用。
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
              let lastActiveAt = entity.lastActiveAt else {
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
              let extra = try? JSONDecoder().decode(SessionExtra.self, from: data) else {
            return SessionExtra()
        }
        return extra
    }
}

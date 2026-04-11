import Foundation

struct SessionExtra: Codable {
    var pluginDirs: [String]?
    var permissionMode: String?
    var addDirs: [String]?
    var model: String?
    var effort: String?

    init(pluginDirs: [String]? = nil, permissionMode: String? = nil, addDirs: [String]? = nil, model: String? = nil, effort: String? = nil) {
        self.pluginDirs = pluginDirs
        self.permissionMode = permissionMode
        self.addDirs = addDirs
        self.model = model
        self.effort = effort
    }
}

/// 新 session 系统的数据模型。与 legacy Session struct 独立，由 SessionService/SessionRepository 使用。
struct SessionRecord: Identifiable {

    let id: UUID
    var sessionId: String
    var title: String
    var cwd: String?
    var isWorktree: Bool
    var originPath: String?
    var createdAt: Date
    var lastActiveAt: Date
    var status: SessionStatus
    var archivedAt: Date?
    var extra: SessionExtra
    var error: String?
    var isPinned: Bool
    var pinnedAt: Date?
    var isTempDir: Bool

    /// slug 从 cwd 确定性推导，不持久化。需与 Claude CLI 的 slug 生成逻辑一致。
    var slug: String? {
        cwd?.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    var folderName: String? {
        guard let cwd else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    var groupingPath: String? {
        originPath ?? cwd
    }

    var groupingFolderName: String? {
        if isTempDir { return "临时会话" }
        guard let path = groupingPath else { return nil }
        return (path as NSString).lastPathComponent
    }

    init(
        id: UUID = UUID(),
        sessionId: String,
        title: String = "[unknown session]",
        cwd: String? = nil,
        isWorktree: Bool = false,
        originPath: String? = nil,
        createdAt: Date = Date(),
        lastActiveAt: Date = Date(),
        status: SessionStatus = .pending,
        archivedAt: Date? = nil,
        extra: SessionExtra = SessionExtra(),
        error: String? = nil,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        isTempDir: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.isWorktree = isWorktree
        self.originPath = originPath
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.status = status
        self.archivedAt = archivedAt
        self.extra = extra
        self.error = error
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isTempDir = isTempDir
    }
}

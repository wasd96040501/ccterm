import Foundation

// MARK: - TodoStatus

enum TodoStatus: String, Codable {
    case pending              // 待处理：刚创建，session 正在预处理中
    case needsConfirmation    // 待确认：模型预处理完成，等待用户确认
    case inProgress           // 进行中：用户已确认，在 session 中交互
    case completed            // 已完成：用户标记完成
    case merged               // 已合并：worktree 分支已合入目标分支，自动归档
}

// MARK: - TodoItemType

enum TodoItemType: String, Codable {
    case normal     // 普通任务：用户创建的需求
    case merge      // 合并任务：系统在批量合并时自动创建
}

// MARK: - TodoMetadata

struct TodoMetadata: Codable {
    var paths: [String]           // 项目路径列表（支持多个）
    var gitBranch: String?        // 基于哪个 git 分支创建 worktree
    var pluginDirs: [String]?     // plugin 目录
}

// MARK: - TodoItem

struct TodoItem: Identifiable {
    let id: UUID
    var title: String               // 用户输入的需求描述
    var status: TodoStatus
    var type: TodoItemType          // 区分普通任务和合并任务
    var metadata: TodoMetadata?     // 可选元数据（路径、分支、plugin）
    var sessionId: String?          // 关联的处理 session
    var worktreeBranch: String?     // worktree 分支名
    var mergedItemIds: [String]?    // 合并任务包含的 todoId 列表（仅 type == .merge）
    var isDeleted: Bool             // 软删除标记
    var deletedAt: Date?            // 删除时间
    var previousStatus: TodoStatus? // 删除前的状态（用于恢复）
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        status: TodoStatus = .pending,
        type: TodoItemType = .normal,
        metadata: TodoMetadata? = nil,
        sessionId: String? = nil,
        worktreeBranch: String? = nil,
        mergedItemIds: [String]? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        previousStatus: TodoStatus? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.type = type
        self.metadata = metadata
        self.sessionId = sessionId
        self.worktreeBranch = worktreeBranch
        self.mergedItemIds = mergedItemIds
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.previousStatus = previousStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

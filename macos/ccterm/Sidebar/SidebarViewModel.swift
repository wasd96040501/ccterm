import SwiftUI
import Observation

// MARK: - Supporting Types

/// Sidebar 专用的展示模型，从 SessionRecord + 运行时状态组合而来。
struct SidebarSession: Identifiable {
    let id: String              // sessionId
    let record: SessionRecord
    let branch: String?
    let isRunning: Bool
    let isWorktree: Bool

    var folderName: String? { record.groupingFolderName }
}

/// 按项目分组的会话列表。
struct ProjectGroup: Identifiable {
    let id: String          // folderName
    let folderName: String
    let colorIndex: Int
    var sessions: [SidebarSession]
}

/// Sidebar 选中状态。
enum SidebarSelection: Hashable {
    case action(SidebarActionKind)
    case session(String)    // sessionId
}

/// 操作区入口。
enum SidebarActionKind: String, Identifiable, CaseIterable, Hashable {
    case newConversation
    case newProject
    case todo
    case archive
    #if DEBUG
    case cardGallery
    case chatGallery
    case planGallery
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newConversation: String(localized: "New Conversation")
        case .newProject: String(localized: "New Project")
        case .todo: String(localized: "Tasks")
        case .archive: String(localized: "Archive")
        #if DEBUG
        case .cardGallery: "Card Gallery"
        case .chatGallery: "Chat Gallery"
        case .planGallery: "Plan Gallery"
        #endif
        }
    }

    var symbolName: String {
        switch self {
        case .newConversation: "square.and.pencil"
        case .newProject: "folder.badge.plus"
        case .todo: "checklist"
        case .archive: "archivebox"
        #if DEBUG
        case .cardGallery: "rectangle.on.rectangle.angled"
        case .chatGallery: "bubble.left.and.bubble.right"
        case .planGallery: "doc.text.magnifyingglass"
        #endif
        }
    }
}

/// 会话行的显示风格。
enum SessionRowStyle {
    /// 运行中分组：彩色胶囊 + stop 按钮
    case running
    /// 置顶分组：彩色胶囊 + unpin + archive 按钮
    case pinned
    /// 项目分组：无胶囊 + pin + archive 按钮
    case project
}

// MARK: - SidebarViewModel

/// Sidebar 的 @Observable ViewModel。纯响应式，不持有会话数据副本。
///
/// 职责：管理 sidebar 的 session 列表数据。自驱动：观察 SessionService 的 handles 状态变化自动 rebuild。
/// **不持有选中状态**——"当前活跃 session"的 source of truth 是 chatRouter.currentSession。
@Observable
@MainActor
final class SidebarViewModel {

    // MARK: - Derived Data (由 rebuildSections 计算)

    private(set) var runningSessions: [SidebarSession] = []
    private(set) var pinnedSessions: [SidebarSession] = []
    private(set) var projectGroups: [ProjectGroup] = []

    // MARK: - UI State

    /// 初始加载是否完成（用于 loading 指示器和渐入动画）。
    private(set) var isLoaded = false

    /// 需要用户关注的 session ID 集合（sidebar 显示未读蓝点）。
    private(set) var unreadSessionIds: Set<String> = []

    /// 已折叠的 section ID 集合（"running" / "pinned" / projectGroup.id）。
    var collapsedSections: Set<String> = []

    // MARK: - Callbacks

    /// 归档 session 时的额外清理回调（由 AppState 注入，用于清理 ChatRouter 缓存）。
    var onArchive: ((String) -> Void)?

    /// 判断某个 session 是否当前活跃（由 AppState 注入）。用于过滤：当前已在该 tab 时丢弃未读通知。
    var isSessionActive: ((String) -> Bool)?

    // MARK: - Dependencies

    private let sessionService: SessionService
    private let gitBranchService: GitBranchService

    // MARK: - Private

    /// 文件夹 → 调色板颜色索引（UserDefaults 持久化）。
    @ObservationIgnored private var folderColorMap: [String: Int] = [:]
    @ObservationIgnored private var nextColorIndex: Int = 0
    @ObservationIgnored private var statusObservation: Task<Void, Never>?
    @ObservationIgnored private var unreadTasks: [String: Task<Void, Never>] = [:]

    private static let folderColorsKey = "sidebarFolderColors"

    /// 5 色调色板。避免蓝色系（与 sidebar 选中高亮冲突）。
    static let palette: [Color] = [
        Color(hue: 0.35, saturation: 0.50, brightness: 0.75), // 橄榄绿
        Color(hue: 0.08, saturation: 0.60, brightness: 0.90), // 琥珀
        Color(hue: 0.47, saturation: 0.50, brightness: 0.80), // 青绿
        Color(hue: 0.92, saturation: 0.50, brightness: 0.85), // 玫红
        Color(hue: 0.75, saturation: 0.45, brightness: 0.80), // 紫藤
    ]

    // MARK: - Lifecycle

    init(sessionService: SessionService, gitBranchService: GitBranchService) {
        self.sessionService = sessionService
        self.gitBranchService = gitBranchService
        loadFolderColors()
    }

    /// 由 View 的 .task { } 调用。
    func loadInitially() async {
        rebuildSections()
        // 等一帧，让 SwiftUI 先渲染 loading 状态，再触发渐入动画
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeInOut(duration: 0.25)) {
            isLoaded = true
        }
        startObservingChanges()
    }

    // MARK: - Rebuild

    func rebuildSections() {
        // 1. 从 Repository 拉全量（过滤 archived）
        let records = sessionService.findAll()

        // 2. 收集所有 cwd，同步 GitBranchService 监控
        let cwds = Set(records.compactMap(\.cwd))
        gitBranchService.sync(paths: cwds)

        // 3. 组装 SidebarSession
        let sessions: [SidebarSession] = records.map { record in
            let handle = sessionService.handle(for: record.sessionId)
            let isRunning = handle?.status.isActive ?? false
            let branch = handle?.branch ?? gitBranchService.branch(for: record.cwd ?? "")
            let isWorktree = handle?.isWorktree ?? record.isWorktree
            return SidebarSession(
                id: record.sessionId,
                record: record,
                branch: branch,
                isRunning: isRunning,
                isWorktree: isWorktree
            )
        }

        // 4. 分区：运行中
        let newRunning = sessions
            .filter { $0.isRunning }
            .sorted { $0.record.lastActiveAt > $1.record.lastActiveAt }

        // 5. 分区：置顶（排除运行中）
        let newPinned = sessions
            .filter { $0.record.isPinned && !$0.isRunning }
            .sorted { $0.record.lastActiveAt > $1.record.lastActiveAt }

        // 6. 剩余按 folderName 分组
        let rest = sessions.filter { !$0.isRunning && !$0.record.isPinned }
        let grouped = Dictionary(grouping: rest) { $0.folderName ?? "未知" }

        let newGroups = grouped.map { (folder, items) in
            let sorted = items.sorted { $0.record.lastActiveAt > $1.record.lastActiveAt }
            return ProjectGroup(
                id: folder,
                folderName: folder,
                colorIndex: colorIndex(for: folder),
                sessions: sorted
            )
        }.sorted {
            guard let a = $0.sessions.first, let b = $1.sessions.first else { return false }
            return a.record.lastActiveAt > b.record.lastActiveAt
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            runningSessions = newRunning
            pinnedSessions = newPinned
            projectGroups = newGroups
        }
    }

    // MARK: - Observation

    private func startObservingChanges() {
        statusObservation?.cancel()
        statusObservation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        // 触摸所有活跃 handle 的 status + branch（unread 通过事件流驱动）
                        for (_, handle) in self.sessionService.allHandles {
                            _ = handle.status
                            _ = handle.branch
                            _ = handle.isWorktree
                        }
                        // 触摸 GitBranchService
                        _ = self.gitBranchService.branchByPath
                    } onChange: {
                        continuation.resume()
                    }
                }

                // 变化后 rebuild + 维护事件订阅
                self.rebuildSections()
                self.syncUnreadSubscriptions()
            }
        }
    }

    // MARK: - Unread Event Subscription

    /// 维护 per-handle 事件订阅。新增 handle 时订阅，移除 handle 时取消。
    private func syncUnreadSubscriptions() {
        let currentHandles = sessionService.allHandles

        // 清理已移除 session 的订阅
        for sessionId in unreadTasks.keys {
            if currentHandles[sessionId] == nil {
                unreadTasks[sessionId]?.cancel()
                unreadTasks.removeValue(forKey: sessionId)
            }
        }

        // 为新 handle 订阅
        for (sessionId, handle) in currentHandles {
            subscribeUnread(sessionId: sessionId, handle: handle)
        }
    }

    private func subscribeUnread(sessionId: String, handle: SessionHandle) {
        guard unreadTasks[sessionId] == nil else { return }
        unreadTasks[sessionId] = Task { [weak self] in
            for await event in handle.eventStream() {
                guard let self else { return }
                switch event {
                case .permissionsChanged(let permissions):
                    if !permissions.isEmpty && self.isSessionActive?(sessionId) != true {
                        self.unreadSessionIds.insert(sessionId)
                    }
                    // 不在这里 remove——只有用户 markSessionRead 才移除
                case .statusChanged(let old, let new):
                    if old == .responding && new == .idle && self.isSessionActive?(sessionId) != true {
                        self.unreadSessionIds.insert(sessionId)
                    }
                case .processExited:
                    break
                }
            }
            self?.unreadTasks.removeValue(forKey: sessionId)
        }
    }

    // MARK: - Unread (纯 UI 状态)

    func markSessionUnread(sessionId: String) {
        unreadSessionIds.insert(sessionId)
    }

    func markSessionRead(sessionId: String) {
        unreadSessionIds.remove(sessionId)
    }

    // MARK: - Section Collapse

    func isSectionExpanded(_ id: String) -> Bool {
        !collapsedSections.contains(id)
    }

    func toggleSection(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedSections.contains(id) {
                collapsedSections.remove(id)
            } else {
                collapsedSections.insert(id)
            }
        }
    }

    // MARK: - Session Actions

    /// 归档 session。调 onArchive（清理 ChatRouter 缓存）+ sessionService.archive + rebuild。
    func archiveSession(_ sessionId: String) {
        onArchive?(sessionId)
        sessionService.archive(sessionId)
        rebuildSections()

        // 运行中的会话异步停止子进程
        if sessionService.isRunning(sessionId) {
            Task { await sessionService.stop(sessionId) }
        }
    }

    func stopSession(_ sessionId: String) {
        Task { await sessionService.stop(sessionId) }
    }

    func jsonlFileURL(for sessionId: String) -> URL? {
        sessionService.jsonlFileURL(for: sessionId)
    }

    // MARK: - Pin/Unpin

    func pinSession(sessionId: String) {
        sessionService.pinSession(sessionId)
        rebuildSections()
    }

    func unpinSession(sessionId: String) {
        sessionService.unpinSession(sessionId)
        rebuildSections()
    }

    // MARK: - Color

    func folderColor(for folderName: String) -> Color {
        let index = colorIndex(for: folderName)
        return Self.palette[index % Self.palette.count]
    }

    private func colorIndex(for folderName: String) -> Int {
        if let index = folderColorMap[folderName] {
            return index
        }
        let index = nextColorIndex
        nextColorIndex += 1
        folderColorMap[folderName] = index
        saveFolderColors()
        return index
    }

    // MARK: - Persistence

    private func loadFolderColors() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.folderColorsKey) as? [String: Int] else { return }
        folderColorMap = dict
        nextColorIndex = (dict.values.max() ?? -1) + 1
    }

    private func saveFolderColors() {
        UserDefaults.standard.set(folderColorMap, forKey: Self.folderColorsKey)
    }
}

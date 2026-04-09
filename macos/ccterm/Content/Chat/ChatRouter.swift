import SwiftUI
import Observation
import AgentSDK

/// Session 生命周期的路由和协调。管理 per-session ViewModel 缓存，
/// 决定"发消息"时走新建/恢复/直发哪条路径。本身不持有 UI 状态。
@Observable
@MainActor
final class ChatRouter {

    // MARK: - Output (View 读取)

    /// 当前活跃的 per-session ViewModel。InputBar 和 ChatView 读这个。
    private(set) var currentSession: ChatSessionViewModel

    /// WebView 容器，ChatView 用于嵌入 NSViewRepresentable。
    let chatContentView = ChatContentView()

    /// Plan 全屏 WebView 单例，启动即挂载（opacity=0），按 key 存多份数据。
    let planWebViewLoader = PlanWebViewLoader()

    /// React 侧是否已完成 conversation 切换。
    private(set) var isContentReady = false

    /// 搜索结果回调。AppState 初始化时注入。
    var onSearchResult: ((Int, Int) -> Void)?

    // MARK: - Dependencies

    private let sessionService: SessionService
    // private let todoSessionCoordinator: TodoSessionCoordinator

    // MARK: - Per-session Cache

    private var sessions: [String: ChatSessionViewModel] = [:]

    // MARK: - Bridge Access

    private var bridge: WebViewBridge { chatContentView.bridge }

    // MARK: - Lifecycle

    init(sessionService: SessionService, todoSessionCoordinator: TodoSessionCoordinator? = nil) {
        self.sessionService = sessionService
        // self.todoSessionCoordinator = todoSessionCoordinator
        // Phase 1: satisfy stored property requirement
        self.currentSession = .newConversation(onRouterAction: { _ in })
        // Phase 2: replace with properly wired instance (self is now available)
        self.currentSession = makeNewConversation()
        // Bridge delegate → self
        chatContentView.bridge.delegate = self
        // Inject bridge into SessionService
        sessionService.setBridge(chatContentView.bridge)
        // Inject plan WebView callbacks
        planWebViewLoader.onTextSelected = { [weak self] range in
            self?.currentSession.pendingCommentSelections.append(range)
            self?.currentSession.focusTextView()
        }
        planWebViewLoader.onSelectionCleared = {
            // Don't clear accumulated quotes when DOM selection is cleared
        }
        planWebViewLoader.onCommentEdit = { [weak self] id, text in
            self?.currentSession.viewingPlanCardVM?.commentStore?.updateComment(id: id, text: text)
        }
        planWebViewLoader.onCommentDelete = { [weak self] id in
            self?.currentSession.viewingPlanCardVM?.commentStore?.removeComment(id: id)
        }
        planWebViewLoader.onSearchResult = { [weak self] total, current in
            self?.currentSession.planSearchTotal = total
            self?.currentSession.planSearchCurrent = current
        }
    }

    private func makeNewConversation() -> ChatSessionViewModel {
        let vm = ChatSessionViewModel.newConversation(onRouterAction: { [weak self] in self?.handleRouterAction($0) })
        vm.planWebViewLoader = planWebViewLoader
        return vm
    }

    private func makeSessionVM(handle: SessionHandle, record: SessionRecord?) -> ChatSessionViewModel {
        let vm = ChatSessionViewModel(
            handle: handle,
            record: record,
            onRouterAction: { [weak self] in self?.handleRouterAction($0) }
        )
        vm.planWebViewLoader = planWebViewLoader
        // vm.todoSessionCoordinator = todoSessionCoordinator
        return vm
    }

    // MARK: - Session Activation

    /// 激活指定 session。Binding setter 和外部跳转调用。
    func activateSession(_ sessionId: String) {
        guard sessionId != currentSession.sessionId else { return }
        currentSession.animationsDisabled = true
        if let cached = sessions[sessionId] {
            currentSession = cached
        } else {
            guard let handle = sessionService.session(sessionId) else { return }
            let record = sessionService.find(sessionId)
            let sessionVM = makeSessionVM(handle: handle, record: record)
            sessions[sessionId] = sessionVM
            currentSession = sessionVM
        }
        currentSession.animationsDisabled = true

        let sid = currentSession.sessionId
        if let handle = currentSession.handle, handle.status == .inactive {
            handle.loadHistoryIfNeeded { [weak self] in
                guard let self, self.currentSession.sessionId == sid else { return }
                self.bridge.switchConversation(sid)
            }
        } else {
            bridge.switchConversation(sid)
        }
        DispatchQueue.main.async { [currentSession] in
            currentSession.animationsDisabled = false
        }
    }

    /// 激活新对话。已经是新对话时 no-op。
    func activateNewConversation() {
        guard currentSession.handle != nil else { return }
        currentSession.animationsDisabled = true
        currentSession = makeNewConversation()
        currentSession.animationsDisabled = true
        bridge.switchConversation(currentSession.sessionId)
        DispatchQueue.main.async { [currentSession] in
            currentSession.animationsDisabled = false
        }
    }

    // MARK: - Message Submission (路由)

    /// 提交用户消息。根据当前 session 状态路由。
    func submitMessage(_ text: String) {
        guard currentSession.barState != .starting else { return }

        // /complete 拦截
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "/complete",
           let handle = currentSession.handle,
           let record = sessionService.find(handle.sessionId),
           record.sessionType == .todo {
            // todoSessionCoordinator.markComplete(sessionId: handle.sessionId)
            return
        }

        if let handle = currentSession.handle, handle.status == .inactive {
            Task { await resumeSession(handle, text) }
        } else if let handle = currentSession.handle {
            handle.send(.text(text))
            // todoSessionCoordinator.handleUserMessage(for: handle.sessionId)
        } else {
            Task { await startNewSession(text) }
        }
    }

    // MARK: - Router Action

    func handleRouterAction(_ action: ChatRouterAction) {
        switch action {
        case .executePlan(let request):
            Task { await startPlanSession(from: request.sourceHandle, plan: request.plan, planFilePath: request.planFilePath) }
        }
    }

    // MARK: - Cache Management

    /// 清理指定 session 的相关资源。session 归档/删除时调用。
    func cleanupSession(_ sessionId: String) {
        sessions[sessionId] = nil
        UserDefaults.standard.removeObject(forKey: "chatInputBarDraft_\(sessionId)")
        sessionService.removeHandle(sessionId)
        if currentSession.sessionId == sessionId {
            activateNewConversation()
        }
    }

    // MARK: - Search (透传)

    func search(query: String, direction: String) {
        bridge.search(query: query, direction: direction)
    }

    // MARK: - Content Ready

    func markContentReady(conversationId: String) {
        if conversationId == currentSession.sessionId {
            isContentReady = true
        }
    }

    func updateScrollState(conversationId: String, isAtBottom: Bool) {
        if conversationId == currentSession.sessionId {
            currentSession.isAtBottom = isAtBottom
        }
    }

    // MARK: - Private: Session Lifecycle

    /// 启动新 session。分为同步 + 异步两个阶段。
    /// 新对话 VM 就地变身：赋上 handle 后从"新对话"变为"具体 session"，
    /// 缓存进 sessions[id]。用户切走时 sessionVM 仍在后台完成。
    private func startNewSession(_ text: String) async {
        // 捕获当前 session VM，防止 await 期间用户切走导致 currentSession 变化
        let sessionVM = currentSession

        let isTempDir = sessionVM.selectedDirectory == nil
        let directory = sessionVM.selectedDirectory ?? Self.createTempChatDirectory()

        let pluginDirs = sessionVM.pluginDirectories
        let config = SessionConfig(
            path: directory,
            isWorktree: sessionVM.isWorktree,
            pluginDirs: pluginDirs.isEmpty ? nil : pluginDirs,
            additionalDirs: sessionVM.additionalDirectories.isEmpty ? nil : sessionVM.additionalDirectories,
            permissionMode: sessionVM.permissionMode,
            model: sessionVM.selectedModel,
            effort: sessionVM.selectedEffort,
            isTempDir: isTempDir
        )

        // ── 同步阶段（立即完成，UI 即时响应）──
        let handle = sessionService.createNewSession(sessionId: sessionVM.sessionId, config: config, title: String(text.prefix(100)))

        sessionVM.selectedDirectory = directory
        sessionVM.isTempDir = isTempDir
        sessionVM.handle = handle  // barState → .starting（handle.status == .starting）
        sessions[handle.sessionId] = sessionVM  // SidebarVM 立即感知

        // ── 异步阶段 ──
        do {
            try await sessionService.start(sessionId: handle.sessionId, config: config)

            // 仅当此 session 仍是当前活跃 session 时切换 WebView
            if currentSession === sessionVM {
                bridge.switchConversation(handle.sessionId)
            }

            handle.send(.text(text))

            // 保存最近目录
            if !isTempDir {
                saveRecentDirectory(directory)
                DirectoryCompletionProvider.saveToRecent(directory)
            }
        } catch {
            NSLog("[ChatRouter] Failed to start session: %@", "\(error)")
            handle.status = .inactive
            sessionVM.processExitError = ProcessExitError(exitCode: 1, stderr: error.localizedDescription)
        }
    }

    /// 恢复已有 session。
    private func resumeSession(_ handle: SessionHandle, _ text: String) async {
        // 同步阶段：UI 置灰
        handle.status = .starting

        let config = SessionConfig(
            path: currentSession.selectedDirectory ?? "",
            isWorktree: currentSession.isWorktree,
            pluginDirs: currentSession.pluginDirectories.isEmpty ? nil : currentSession.pluginDirectories,
            additionalDirs: currentSession.additionalDirectories.isEmpty ? nil : currentSession.additionalDirectories,
            permissionMode: currentSession.permissionMode,
            model: currentSession.selectedModel,
            effort: currentSession.selectedEffort
        )
        do {
            try await sessionService.start(sessionId: handle.sessionId, config: config)
            handle.send(.text(text))
        } catch {
            NSLog("[ChatRouter] Resume failed: %@", "\(error)")
            handle.status = .inactive
        }
    }

    /// ExitPlanMode: 停止旧 session，启动新 session 执行 plan。
    private func startPlanSession(from sourceHandle: SessionHandle, plan: String, planFilePath: String?) async {
        let record = sessionService.find(sourceHandle.sessionId)
        let directory = record?.cwd ?? ""
        let slug = record?.slug ?? ""

        await sessionService.stop(sourceHandle.sessionId)

        let transcriptPath = NSString(string: "~/.claude/projects/\(slug)/\(sourceHandle.sessionId).jsonl")
            .expandingTildeInPath
        let prompt = """
            Implement the following plan:

            \(plan)

            If you need specific details from before exiting plan mode, \
            read the full transcript at: \(transcriptPath)
            """

        let config = SessionConfig(
            path: directory,
            isWorktree: false,
            pluginDirs: record?.extra.pluginDirs,
            additionalDirs: record?.extra.addDirs,
            permissionMode: .acceptEdits
        )

        do {
            let newHandle = try await sessionService.start(config: config)

            let sessionVM = makeSessionVM(handle: newHandle, record: nil)
            sessions[newHandle.sessionId] = sessionVM
            activateSession(newHandle.sessionId)
            newHandle.send(.text(prompt))
        } catch {
            NSLog("[ChatRouter] startPlanSession failed: %@", "\(error)")
        }
    }

    // MARK: - Directory Management

    private static let recentDirectoriesKey = "recentWorkingDirectories"
    private static let maxRecentDirectories = 20

    private func saveRecentDirectory(_ path: String) {
        var recents = UserDefaults.standard.stringArray(forKey: Self.recentDirectoriesKey) ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > Self.maxRecentDirectories {
            recents = Array(recents.prefix(Self.maxRecentDirectories))
        }
        UserDefaults.standard.set(recents, forKey: Self.recentDirectoriesKey)
    }

    // MARK: - Temp Directory

    private static func createTempChatDirectory() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("ccterm/temp-chats")
        var dir: String
        repeat {
            let shortId = String(UUID().uuidString.filter { $0 != "-" }.lowercased().prefix(8))
            dir = base.appendingPathComponent(shortId).path
        } while FileManager.default.fileExists(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - WebViewBridgeDelegate

extension ChatRouter: WebViewBridgeDelegate {

    func bridge(_ bridge: WebViewBridge, didReceive event: WebEvent) {
        switch event {
        case .ready(let conversationId):
            markContentReady(conversationId: conversationId)
        case .searchResult(let total, let current):
            onSearchResult?(total, current)
        case .scrollStateChanged(let conversationId, let isAtBottom):
            updateScrollState(conversationId: conversationId, isAtBottom: isAtBottom)
        }
    }
}

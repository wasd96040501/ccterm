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
    private(set) var currentViewModel: InputBarViewModel

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

    // MARK: - Per-session Cache

    private var viewModels: [String: InputBarViewModel] = [:]

    /// 尚未启动的新对话 VM 缓存。启动后清空，不持久化。
    private var pendingNewViewModel: InputBarViewModel?

    // MARK: - Bridge Access

    private var bridge: WebViewBridge { chatContentView.bridge }

    // MARK: - Lifecycle

    init(sessionService: SessionService) {
        self.sessionService = sessionService
        // Phase 1: satisfy stored property requirement
        self.currentViewModel = .newConversation(onRouterAction: { _ in })
        // Phase 2: replace with properly wired instance (self is now available)
        self.currentViewModel = makeNewViewModel()
        // Bridge delegate → self
        chatContentView.bridge.delegate = self
        // Inject bridge into SessionService
        sessionService.setBridge(chatContentView.bridge)
        // Inject plan WebView callbacks
        planWebViewLoader.onTextSelected = { [weak self] range in
            self?.currentViewModel.planReviewVM.pendingCommentSelections.append(range)
            self?.currentViewModel.inputVM.focusTextView()
        }
        planWebViewLoader.onSelectionCleared = {
            // Don't clear accumulated quotes when DOM selection is cleared
        }
        planWebViewLoader.onCommentEdit = { [weak self] id, text in
            self?.currentViewModel.planReviewVM.viewingCardVM?.commentStore?.updateComment(id: id, text: text)
        }
        planWebViewLoader.onCommentDelete = { [weak self] id in
            self?.currentViewModel.planReviewVM.viewingCardVM?.commentStore?.removeComment(id: id)
        }
        planWebViewLoader.onSearchResult = { [weak self] total, current in
            self?.currentViewModel.planReviewVM.searchTotal = total
            self?.currentViewModel.planReviewVM.searchCurrent = current
        }
    }

    private func makeNewViewModel() -> InputBarViewModel {
        let vm = InputBarViewModel.newConversation(
            onRouterAction: { [weak self] in self?.handleRouterAction($0) },
            onSend: { [weak self] in self?.submitMessage($0) },
            planWebViewLoader: planWebViewLoader
        )
        return vm
    }

    private func makeViewModel(handle: SessionHandle, record: SessionRecord?) -> InputBarViewModel {
        let vm = InputBarViewModel(
            handle: handle,
            record: record,
            onRouterAction: { [weak self] in self?.handleRouterAction($0) },
            onSend: { [weak self] in self?.submitMessage($0) },
            planWebViewLoader: planWebViewLoader
        )
        return vm
    }

    // MARK: - Session Activation

    /// 激活指定 session。Binding setter 和外部跳转调用。
    func activateSession(_ sessionId: String) {
        guard sessionId != currentViewModel.sessionId else { return }
        currentViewModel.animationsDisabled = true
        if let cached = viewModels[sessionId] {
            currentViewModel = cached
        } else {
            guard let handle = sessionService.session(sessionId) else { return }
            let record = sessionService.find(sessionId)
            let vm = makeViewModel(handle: handle, record: record)
            viewModels[sessionId] = vm
            currentViewModel = vm
        }
        currentViewModel.animationsDisabled = true

        let sid = currentViewModel.sessionId
        if let handle = currentViewModel.handle, handle.status == .inactive {
            handle.loadHistoryIfNeeded { [weak self] in
                guard let self, self.currentViewModel.sessionId == sid else { return }
                self.bridge.switchConversation(sid)
            }
        } else {
            bridge.switchConversation(sid)
        }
        DispatchQueue.main.async { [currentViewModel] in
            currentViewModel.animationsDisabled = false
        }
    }

    /// 激活新对话。已经是新对话时 no-op。
    func activateNewConversation() {
        guard currentViewModel.handle != nil else { return }
        currentViewModel.animationsDisabled = true
        if let pending = pendingNewViewModel, pending.handle == nil {
            currentViewModel = pending
        } else {
            let vm = makeNewViewModel()
            pendingNewViewModel = vm
            currentViewModel = vm
        }
        currentViewModel.animationsDisabled = true
        bridge.switchConversation(currentViewModel.sessionId)
        DispatchQueue.main.async { [currentViewModel] in
            currentViewModel.animationsDisabled = false
        }
    }

    // MARK: - Message Submission (路由)

    /// 提交用户消息。根据当前 session 状态路由。
    func submitMessage(_ text: String) {
        guard currentViewModel.barState != .starting else { return }

        if let handle = currentViewModel.handle, handle.status == .inactive {
            Task { await resumeSession(handle, text) }
        } else if let handle = currentViewModel.handle {
            handle.send(.text(text))
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

    /// 清理指定 session 的相关资源。
    func cleanupSession(_ sessionId: String) {
        viewModels[sessionId] = nil
        UserDefaults.standard.removeObject(forKey: "chatInputBarDraft_\(sessionId)")
        sessionService.removeHandle(sessionId)
        if currentViewModel.sessionId == sessionId {
            activateNewConversation()
        }
    }

    // MARK: - Search (透传)

    func search(query: String, direction: String) {
        bridge.search(query: query, direction: direction)
    }

    // MARK: - Content Ready

    func markContentReady(conversationId: String) {
        if conversationId == currentViewModel.sessionId {
            isContentReady = true
        }
    }

    func updateScrollState(conversationId: String, isAtBottom: Bool) {
        if conversationId == currentViewModel.sessionId {
            currentViewModel.isAtBottom = isAtBottom
        }
    }

    // MARK: - Private: Session Lifecycle

    private func handleEditMessage(_ newText: String) async {
        let sessionVM = currentViewModel
        guard let handle = sessionVM.handle else {
            submitMessage(newText)
            return
        }
        await sessionService.stop(handle.sessionId)
        sessionVM.handle = nil
        submitMessage(newText)
    }

    private func startNewSession(_ text: String) async {
        let sessionVM = currentViewModel

        let isTempDir = sessionVM.originPath == nil
        let directory = sessionVM.originPath ?? Self.createTempChatDirectory()

        let pluginDirs = sessionVM.pluginDirectories
        let config = SessionConfig(
            originPath: directory,
            isWorktree: sessionVM.isWorktree,
            worktreeBaseBranch: sessionVM.worktreeBaseBranch,
            pluginDirs: pluginDirs.isEmpty ? nil : pluginDirs,
            additionalDirs: sessionVM.additionalDirectories.isEmpty ? nil : sessionVM.additionalDirectories,
            permissionMode: sessionVM.permissionMode,
            model: sessionVM.selectedModel,
            effort: sessionVM.selectedEffort,
            isTempDir: isTempDir
        )

        // Create handle first so UI enters .starting immediately
        let handle = sessionService.provisionSession(sessionId: sessionVM.sessionId, config: config, title: String(text.prefix(100)))

        sessionVM.originPath = directory
        sessionVM.isTempDir = isTempDir
        viewModels[sessionVM.sessionId] = sessionVM
        if pendingNewViewModel === sessionVM {
            pendingNewViewModel = nil
        }

        // 先赋 handle，让 View 树安定（空状态消失、computed 属性更新）
        sessionVM.handle = handle

        // 让出执行权，确保 View 树重排完成
        await Task.yield()

        // 在干净的 View 状态上动画 .starting
        withAnimation(.smooth(duration: 0.35)) {
            handle.status = .starting
        }

        do {
            try await sessionService.launch(sessionId: handle.sessionId, config: config, taskDescription: text)
            if currentViewModel === sessionVM {
                bridge.switchConversation(handle.sessionId)
            }
            handle.send(.text(text))
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

    private func resumeSession(_ handle: SessionHandle, _ text: String) async {
        withAnimation(.smooth(duration: 0.35)) {
            handle.status = .starting
        }

        let config = SessionConfig(
            originPath: currentViewModel.originPath ?? "",
            isWorktree: currentViewModel.isWorktree,
            pluginDirs: currentViewModel.pluginDirectories.isEmpty ? nil : currentViewModel.pluginDirectories,
            additionalDirs: currentViewModel.additionalDirectories.isEmpty ? nil : currentViewModel.additionalDirectories,
            permissionMode: currentViewModel.permissionMode,
            model: currentViewModel.selectedModel,
            effort: currentViewModel.selectedEffort
        )
        do {
            try await sessionService.relaunch(sessionId: handle.sessionId, config: config)
            handle.send(.text(text))
        } catch {
            NSLog("[ChatRouter] Resume failed: %@", "\(error)")
            handle.status = .inactive
        }
    }

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

        let sessionId = UUID().uuidString
        let config = SessionConfig(
            originPath: directory,
            isWorktree: false,
            pluginDirs: record?.extra.pluginDirs,
            additionalDirs: record?.extra.addDirs,
            permissionMode: .acceptEdits
        )

        do {
            let newHandle = sessionService.provisionSession(sessionId: sessionId, config: config, title: "Plan execution")
            newHandle.status = .starting

            try await sessionService.launch(sessionId: sessionId, config: config)

            let sessionVM = makeViewModel(handle: newHandle, record: nil)
            viewModels[newHandle.sessionId] = sessionVM
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
        case .editMessage(_, let newText):
            submitMessage(newText)
        case .forkMessage:
            break
        }
    }
}

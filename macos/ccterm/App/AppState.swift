import SwiftUI
import Observation
import AgentSDK

@Observable
@MainActor
final class AppState {
    // MARK: - Services
    let sessionService = SessionService()
    let sessionManager2 = SessionManager2()
    let gitBranchService = GitBranchService()
    let syntaxEngine = SyntaxHighlightEngine()
    // MARK: - ViewModels
    let sidebarViewModel: SidebarViewModel
    let chatRouter: ChatRouter

    // MARK: - Navigation
    /// 非 chat 页面标识。nil 表示当前在 chat 模式。
    var activeAction: SidebarActionKind?

    // MARK: - Search State
    var searchQuery = ""
    var searchTotal = 0
    var searchCurrent = 0
    var searchFocusTrigger = false

    init() {
        let sessionService = self.sessionService
        let gitBranchService = self.gitBranchService

        let sidebarVM = SidebarViewModel(
            sessionService: sessionService,
            gitBranchService: gitBranchService
        )
        self.sidebarViewModel = sidebarVM

        let router = ChatRouter(
            sessionService: sessionService
        )
        self.chatRouter = router

        // 搜索结果回调
        router.onSearchResult = { [weak self] total, current in
            self?.searchTotal = total
            self?.searchCurrent = current
        }

        // 归档回调：清理 ChatRouter 缓存
        sidebarVM.onArchive = { [weak router] sessionId in
            router?.cleanupSession(sessionId)
        }

        // 活跃 session 判断：当前已在该 tab 时丢弃未读通知
        sidebarVM.isSessionActive = { [weak router, weak self] sessionId in
            guard let self, self.activeAction == nil else { return false }
            return router?.currentViewModel.sessionId == sessionId
        }

        // App 退出时清理子进程
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.sessionService.stopAll() }
        }

        // Eagerly load the syntax highlight engine in the background so the
        // first `highlightBatch` call doesn't pay the JSCore / highlight.js
        // init cost (~30ms) on the user-facing path. `.utility` priority keeps
        // it behind real user interactions.
        let engine = syntaxEngine
        Task.detached(priority: .utility) { await engine.load() }
    }

    // MARK: - Search Actions

    func searchTextChanged(_ query: String) {
        if query.isEmpty {
            chatRouter.search(query: "", direction: "reset")
            searchTotal = 0
            searchCurrent = 0
        } else {
            chatRouter.search(query: query, direction: "reset")
        }
    }

    func findNext() {
        let vm = chatRouter.currentViewModel
        if vm.planReviewVM.isActive {
            chatRouter.planWebViewLoader.search(
                query: vm.planReviewVM.searchQuery, direction: "next"
            )
        } else {
            guard !searchQuery.isEmpty else { return }
            chatRouter.search(query: searchQuery, direction: "next")
        }
    }

    func findPrevious() {
        let vm = chatRouter.currentViewModel
        if vm.planReviewVM.isActive {
            chatRouter.planWebViewLoader.search(
                query: vm.planReviewVM.searchQuery, direction: "prev"
            )
        } else {
            guard !searchQuery.isEmpty else { return }
            chatRouter.search(query: searchQuery, direction: "prev")
        }
    }

    func startNewConversation() {
        activeAction = nil
        chatRouter.activateNewConversation()
        chatRouter.currentViewModel.inputVM.focusTextView()
    }

    func dismissSearch() {
        let vm = chatRouter.currentViewModel
        if vm.planReviewVM.isActive {
            vm.planReviewVM.searchQuery = ""
            chatRouter.planWebViewLoader.search(query: "", direction: "reset")
        } else {
            chatRouter.search(query: "", direction: "reset")
            searchQuery = ""
            searchTotal = 0
            searchCurrent = 0
        }
    }

}

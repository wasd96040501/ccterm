import SwiftUI
import Observation
import AgentSDK

@Observable
@MainActor
final class AppState {
    // MARK: - Services
    let sessionService = SessionService()
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

        // Load syntax highlight engine asynchronously
        let engine = syntaxEngine
        Task { await engine.load() }
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

    // MARK: - Plan Gallery (DEBUG)

    #if DEBUG
    func activatePlanGallery() {
        // Activate a real session
        let sessions = sessionService.findAll()
        if let target = sessions.first {
            activeAction = nil
            chatRouter.activateSession(target.sessionId)
        }

        // Inject mock ExitPlanMode permission card
        let currentVM = chatRouter.currentViewModel
        let cardId = "gallery-plan-mock"
        let plan = Self.galleryPlan
        let request = PermissionRequest.makePreview(
            requestId: cardId,
            toolName: "ExitPlanMode",
            input: ["plan": plan]
        )
        let vm = ExitPlanModeCardViewModel(
            request: request,
            onDecision: { decision in
                NSLog("[PlanGallery] Decision: \(decision)")
            },
            onNewSession: {
                NSLog("[PlanGallery] New session requested")
            }
        )

        vm.onViewPlan = { [weak currentVM] in
            currentVM?.planReviewVM.enter(permissionId: cardId)
        }
        vm.onExecute = { [weak currentVM] mode in
            currentVM?.planReviewVM.executePlan(mode: mode)
        }

        // Push plan to singleton loader
        if let md = vm.planMarkdown, !md.isEmpty {
            currentVM.planWebViewLoader?.setPlan(key: cardId, markdown: md)
        }

        let card = PermissionCardItem(id: cardId, cardType: .exitPlanMode(vm))
        currentVM.permissionVM.cards = [card]
    }

    private static let galleryPlan = """
    ## Architecture Redesign: Permission System v2

    ### Phase 1: Data Layer Refactoring
    - Extract `PermissionRule` protocol from current inline logic
    - Create `PermissionRuleEngine` that evaluates rules in priority order
    - Add persistent storage for user-defined always-allow rules
    - Migrate existing `allowOnce` / `allowAlways` to rule-based system

    ### Phase 2: UI Modernization
    - Replace current card-based UI with a unified permission sheet
    - Add search and filter to the permission history view
    - Implement batch approve/deny for multiple pending permissions
    - Add "remember for this session" option alongside always/once

    ### Phase 3: Security Hardening
    - Add rate limiting for permission requests (prevent permission fatigue attacks)
    - Implement permission scoping by directory and file pattern
    - Add audit log for all permission decisions with timestamps
    - Create admin-level override rules via managed settings

    ### Phase 4: Developer Experience
    - Add permission simulation mode for testing
    - Create permission rule debugger showing which rule matched
    - Implement permission telemetry dashboard
    - Add CI integration for permission policy testing

    ### Migration Strategy
    1. Ship new engine behind feature flag
    2. Dual-write decisions to old and new systems
    3. Validate parity for 2 weeks
    4. Switch reads to new system
    5. Remove old code paths

    ### Code Changes

    ```swift
    protocol PermissionRule {
        var priority: Int { get }
        func evaluate(_ request: PermissionRequest) -> PermissionDecision?
    }

    class PermissionRuleEngine {
        private var rules: [PermissionRule] = []

        func addRule(_ rule: PermissionRule) {
            rules.append(rule)
            rules.sort { $0.priority > $1.priority }
        }

        func evaluate(_ request: PermissionRequest) -> PermissionDecision {
            for rule in rules {
                if let decision = rule.evaluate(request) {
                    return decision
                }
            }
            return .askUser
        }
    }
    ```

    ### Timeline
    - Phase 1: Week 1-2
    - Phase 2: Week 3-4
    - Phase 3: Week 5-6
    - Phase 4: Week 7-8
    """
    #endif
}

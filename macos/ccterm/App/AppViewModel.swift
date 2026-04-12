import SwiftUI
import Observation
import AgentSDK

@Observable
@MainActor
final class AppViewModel {

    // MARK: - Services

    let sessionService = SessionService()
    let chatRendererService = ChatRendererService()
    let planRendererService = PlanRendererService()
    let gitBranchService = GitBranchService()
    let syntaxEngine = SyntaxHighlightEngine()

    // MARK: - ViewModels

    let sidebarViewModel: SidebarViewModel

    // MARK: - Navigation

    /// 非 chat 页面标识。nil 表示当前在 chat 模式。
    var activeAction: SidebarActionKind?

    /// React 侧是否已完成 conversation 切换。
    var isContentReady = false

    // MARK: - Search State

    var searchQuery = ""
    var searchTotal = 0
    var searchCurrent = 0
    var searchFocusTrigger = false

    init() {
        let sessionService = self.sessionService
        let gitBranchService = self.gitBranchService
        let chatRenderer = self.chatRendererService
        let planRenderer = self.planRendererService

        let sidebarVM = SidebarViewModel(
            sessionService: sessionService,
            gitBranchService: gitBranchService
        )
        self.sidebarViewModel = sidebarVM

        // Bridge -> SessionService
        sessionService.setBridge(chatRenderer.bridge)

        // Bridge delegate
        chatRenderer.bridge.delegate = self

        // Plan renderer callbacks
        planRenderer.onTextSelected = { [weak sessionService] range in
            sessionService?.activeHandle?.pendingCommentSelections.append(range)
        }
        planRenderer.onSelectionCleared = {
            // Don't clear accumulated quotes when DOM selection is cleared
        }
        planRenderer.onCommentEdit = { [weak self] id, text in
            self?.currentPlanCardVM?.commentStore?.updateComment(id: id, text: text)
        }
        planRenderer.onCommentDelete = { [weak self] id in
            self?.currentPlanCardVM?.commentStore?.removeComment(id: id)
        }
        planRenderer.onSearchResult = { [weak self] total, current in
            self?.searchTotal = total
            self?.searchCurrent = current
        }

        // 初始新对话
        sessionService.activateNewConversation()

        // 归档回调
        sidebarVM.onArchive = { [weak sessionService] sessionId in
            sessionService?.cleanupSession(sessionId)
        }

        // 活跃 session 判断
        sidebarVM.isSessionActive = { [weak sessionService, weak self] sessionId in
            guard let self, self.activeAction == nil else { return false }
            return sessionService?.activeSessionId == sessionId
        }

        // App 退出时清理子进程
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak sessionService] _ in
            Task { await sessionService?.stopAll() }
        }

        // Load syntax highlight engine asynchronously
        let engine = syntaxEngine
        Task { await engine.load() }
    }

    // MARK: - Plan Card Access

    /// 当前 handle 的 permission cards 中查找 ExitPlanMode card VM。
    private var currentPlanCardVM: ExitPlanModeCardViewModel? {
        guard let handle = sessionService.activeHandle,
              let reviewId = handle.activePlanReviewId else { return nil }
        for permission in handle.pendingPermissions {
            let cardType = permissionCardTypes[permission.id]
            if case .exitPlanMode(let vm) = cardType {
                if permission.id == reviewId { return vm }
            }
        }
        return nil
    }

    /// 缓存 per-permission card type VMs（permission card 生命周期内稳定）。
    var permissionCardTypes: [String: PermissionCardType] = [:]

    // MARK: - Search Actions

    func searchTextChanged(_ query: String) {
        if query.isEmpty {
            chatRendererService.bridge.search(query: "", direction: "reset")
            searchTotal = 0
            searchCurrent = 0
        } else {
            chatRendererService.bridge.search(query: query, direction: "reset")
        }
    }

    func findNext() {
        if let handle = sessionService.activeHandle, handle.activePlanReviewId != nil {
            planRendererService.search(query: handle.planSearchQuery, direction: "next")
        } else {
            guard !searchQuery.isEmpty else { return }
            chatRendererService.bridge.search(query: searchQuery, direction: "next")
        }
    }

    func findPrevious() {
        if let handle = sessionService.activeHandle, handle.activePlanReviewId != nil {
            planRendererService.search(query: handle.planSearchQuery, direction: "prev")
        } else {
            guard !searchQuery.isEmpty else { return }
            chatRendererService.bridge.search(query: searchQuery, direction: "prev")
        }
    }

    func startNewConversation() {
        activeAction = nil
        sessionService.activateNewConversation()
    }

    func dismissSearch() {
        if let handle = sessionService.activeHandle, handle.activePlanReviewId != nil {
            handle.planSearchQuery = ""
            planRendererService.search(query: "", direction: "reset")
        } else {
            chatRendererService.bridge.search(query: "", direction: "reset")
            searchQuery = ""
            searchTotal = 0
            searchCurrent = 0
        }
    }

    // MARK: - Plan Gallery (DEBUG)

    #if DEBUG
    func activatePlanGallery() {
        let sessions = sessionService.findAll()
        if let target = sessions.first {
            activeAction = nil
            sessionService.activateSession(target.sessionId)
        }

        guard let handle = sessionService.activeHandle else { return }
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
                appLog(.debug, "PlanGallery", "Decision: \(decision)")
            },
            onNewSession: {
                appLog(.debug, "PlanGallery", "New session requested")
            }
        )

        vm.onViewPlan = { [weak handle] in
            handle?.activePlanReviewId = cardId
        }
        vm.onExecute = { [weak self, weak handle] mode in
            self?.executePlanFromReview(handle: handle, mode: mode)
        }

        if let md = vm.planMarkdown, !md.isEmpty {
            planRendererService.setPlan(key: cardId, markdown: md)
        }

        permissionCardTypes[cardId] = .exitPlanMode(vm)
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

    // MARK: - Plan Execution Helper

    func executePlanFromReview(handle: SessionHandle?, mode: PlanExecutionMode) {
        guard let handle else { return }
        // Find the plan card VM
        guard let reviewId = handle.activePlanReviewId else { return }
        var planCardVM: ExitPlanModeCardViewModel?
        if let cardType = permissionCardTypes[reviewId], case .exitPlanMode(let vm) = cardType {
            planCardVM = vm
        }
        guard let vm = planCardVM else { return }

        let requestId = vm.request.requestId
        // Exit plan review mode
        handle.activePlanReviewId = nil
        handle.pendingCommentSelections.removeAll()
        handle.planCommentText = ""
        handle.planSearchQuery = ""

        PlanCommentStore.cleanup(permissionRequestId: requestId)

        switch mode {
        case .clearContextAutoAccept:
            vm.executeNewSession()
        case .autoAcceptEdits:
            vm.executeAllow()
            handle.selectPermissionMode(.acceptEdits)
        case .manualApprove:
            vm.executeAllow()
        }
    }

    // MARK: - Router Action Handling

    func handleRouterAction(_ action: ChatRouterAction) {
        switch action {
        case .executePlan(let request):
            Task {
                await sessionService.startPlanSession(
                    from: request.sourceHandle,
                    plan: request.plan,
                    planFilePath: request.planFilePath
                )
            }
        }
    }
}

// MARK: - WebViewBridgeDelegate

extension AppViewModel: WebViewBridgeDelegate {

    func bridge(_ bridge: WebViewBridge, didReceive event: WebEvent) {
        switch event {
        case .ready(let conversationId):
            if conversationId == sessionService.activeSessionId {
                isContentReady = true
            }
        case .searchResult(let total, let current):
            searchTotal = total
            searchCurrent = current
        case .scrollStateChanged(let conversationId, let isAtBottom):
            sessionService.handle(for: conversationId)?.isAtBottom = isAtBottom
        case .editMessage(_, let newText):
            if let handle = sessionService.activeHandle {
                Task {
                    await sessionService.stop(handle.sessionId)
                    sessionService.submitMessage(handle: handle, text: newText)
                }
            }
        case .forkMessage:
            break
        }
    }
}

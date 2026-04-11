import SwiftUI
import Observation
import AgentSDK

/// Plan 评论/搜索/执行状态管理。
@Observable
@MainActor
final class PlanReviewViewModel {

    // MARK: - Plan Viewing State

    /// 正在全屏阅读的 plan 对应的 permission request ID。nil = 未在阅读。
    var viewingPermissionId: String?

    var isActive: Bool { viewingPermissionId != nil }

    /// 已引用的文本片段（React 侧 textSelected 事件追加）。
    var pendingCommentSelections: [PlanComment.SelectionRange] = []

    /// Plan 模式搜索状态。
    var searchQuery: String = ""
    var searchTotal: Int = 0
    var searchCurrent: Int = 0

    /// Execute 二次确认弹窗状态。
    var pendingExecuteMode: PlanExecutionMode?
    var showExecuteConfirmation: Bool { pendingExecuteMode != nil }

    /// Plan 评论专用文本，独立于 inputVM.text。
    var commentText: String = ""

    /// 评论模式下是否可发送评论。
    var canSendComment: Bool { !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Dependencies

    weak var planWebViewLoader: PlanWebViewLoader?
    @ObservationIgnored var setPermissionMode: (PermissionMode) -> Void
    @ObservationIgnored var getPermissionCards: () -> [PermissionCardItem]

    // MARK: - Init

    init(
        planWebViewLoader: PlanWebViewLoader?,
        setPermissionMode: @escaping (PermissionMode) -> Void,
        getPermissionCards: @escaping () -> [PermissionCardItem]
    ) {
        self.planWebViewLoader = planWebViewLoader
        self.setPermissionMode = setPermissionMode
        self.getPermissionCards = getPermissionCards
    }

    // MARK: - Computed

    /// 当前阅读的 plan 对应的 ExitPlanModeCardViewModel。
    var viewingCardVM: ExitPlanModeCardViewModel? {
        guard let id = viewingPermissionId,
              let card = getPermissionCards().first(where: { $0.id == id }),
              case .exitPlanMode(let vm) = card.cardType else { return nil }
        return vm
    }

    /// 当前 permission cards 中的 ExitPlanMode card（不要求处于 plan 全屏）。
    private var currentPlanCardVM: ExitPlanModeCardViewModel? {
        for card in getPermissionCards() {
            if case .exitPlanMode(let vm) = card.cardType { return vm }
        }
        return nil
    }

    // MARK: - Actions

    func enter(permissionId: String) {
        appLog(.debug, "PlanDebug", "enterPlanView id=\(permissionId)")
        let cards = getPermissionCards()
        appLog(.debug, "PlanDebug", "  permissionCards.count=\(cards.count) ids=\(cards.map(\.id).description)")
        planWebViewLoader?.switchPlan(key: permissionId)
        viewingPermissionId = permissionId
    }

    func exit() {
        viewingPermissionId = nil
        pendingCommentSelections.removeAll()
        commentText = ""
        searchQuery = ""
        searchTotal = 0
        searchCurrent = 0
        pendingExecuteMode = nil
    }

    func executePlan(mode: PlanExecutionMode) {
        guard let vm = viewingCardVM ?? currentPlanCardVM else { return }
        let requestId = vm.request.requestId
        exit()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        switch mode {
        case .clearContextAutoAccept:
            vm.executeNewSession()
        case .autoAcceptEdits:
            vm.executeAllow()
            setPermissionMode(.acceptEdits)
        case .manualApprove:
            vm.executeAllow()
        }
    }

    func rejectPlan() {
        guard let vm = viewingCardVM else { return }
        let requestId = vm.request.requestId
        exit()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        vm.executeDeny()
    }

    func revisePlan() {
        guard let vm = viewingCardVM, let store = vm.commentStore else { return }
        let feedback = store.assembleFeedback()
        let requestId = vm.request.requestId
        exit()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        vm.executeDenyWithFeedback(feedback)
    }

    func sendComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let cardVM = viewingCardVM else { return }

        if !pendingCommentSelections.isEmpty {
            for selection in pendingCommentSelections {
                cardVM.commentStore?.addInlineComment(text: text, range: selection)
            }
            pendingCommentSelections.removeAll()
            planWebViewLoader?.clearSelection()
        } else {
            cardVM.commentStore?.addGlobalComment(text: text)
        }
        commentText = ""
    }

    /// 当 permission cards 更新后检查 viewing plan 是否被移除。
    func handlePermissionCardsUpdated() {
        if let viewingId = viewingPermissionId,
           !getPermissionCards().contains(where: { $0.id == viewingId }) {
            viewingPermissionId = nil
            pendingCommentSelections.removeAll()
            commentText = ""
        }
    }
}

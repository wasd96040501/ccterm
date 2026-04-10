import SwiftUI
import AgentSDK

/// 权限卡片列表管理。持有 permission cards 和当前索引。
@Observable
@MainActor
final class PermissionViewModel {

    // MARK: - State

    var cards: [PermissionCardItem] = []
    var currentIndex: Int = 0

    var isActive: Bool { !cards.isEmpty }

    var currentCard: PermissionCardItem? {
        cards[safe: currentIndex]
    }

    // MARK: - Dependencies

    weak var planWebViewLoader: PlanWebViewLoader?
    let onRouterAction: (ChatRouterAction) -> Void
    /// 进入 Plan 全屏模式的回调（传递 permissionId）。
    @ObservationIgnored var onViewPlan: (String) -> Void
    /// 执行 Plan 的回调（传递执行模式）。
    @ObservationIgnored var onExecutePlan: (PlanExecutionMode) -> Void

    // MARK: - Init

    init(
        planWebViewLoader: PlanWebViewLoader?,
        onRouterAction: @escaping (ChatRouterAction) -> Void,
        onViewPlan: @escaping (String) -> Void,
        onExecutePlan: @escaping (PlanExecutionMode) -> Void
    ) {
        self.planWebViewLoader = planWebViewLoader
        self.onRouterAction = onRouterAction
        self.onViewPlan = onViewPlan
        self.onExecutePlan = onExecutePlan
    }

    // MARK: - Rebuild

    /// 根据 handle.pendingPermissions 重建 permission card ViewModels。
    /// 复用已有 CardVM（保留评论、Radio 选中状态），只为新增 ID 创建新 VM。
    func rebuild(from pending: [PendingPermission], handle: SessionHandle?) {
        let currentIds = Set(cards.map(\.id))
        let newIds = Set(pending.map(\.id))
        guard currentIds != newIds else { return }

        NSLog("[PlanDebug] rebuildPermissionCards: old=%@ new=%@", currentIds.sorted().description, newIds.sorted().description)

        let existingByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })

        // Detect removed ids and clearPlan for them
        let removedIds = currentIds.subtracting(newIds)
        for removedId in removedIds {
            planWebViewLoader?.clearPlan(key: removedId)
        }

        cards = pending.map { permission in
            if let existing = existingByID[permission.id] {
                return existing
            }

            let cardType = PermissionCardViewModelFactory.make(
                for: permission.request,
                onDecision: { decision in permission.respond(decision) },
                onNewSession: { [weak handle, weak self] in
                    guard let handle, let self else { return }
                    let plan = InputBarViewModel.extractPlan(from: permission.request)
                    let planFilePath = InputBarViewModel.extractPlanFilePath(from: permission.request)
                    self.onRouterAction(.executePlan(PlanRequest(sourceHandle: handle, plan: plan, planFilePath: planFilePath)))
                }
            )

            NSLog("[PlanDebug] rebuildPermissionCards: NEW card id=%@ toolName=%@ cardType=%@", permission.id, permission.request.toolName, String(describing: cardType))

            if case .exitPlanMode(let vm) = cardType {
                NSLog("[PlanDebug]   exitPlanMode hasPlan=%@", String(describing: vm.hasPlan))
                vm.onViewPlan = { [weak self] in
                    self?.onViewPlan(permission.id)
                }
                vm.onExecute = { [weak self] mode in
                    self?.onExecutePlan(mode)
                }

                // Push plan markdown to singleton loader
                if let md = vm.planMarkdown, !md.isEmpty {
                    let planKey = permission.id
                    planWebViewLoader?.setPlan(key: planKey, markdown: md)

                    // Wire commentStore callbacks (带 key)
                    vm.commentStore?.onCommentsChanged = { [weak self] comments in
                        self?.planWebViewLoader?.setComments(key: planKey, comments: comments)
                    }
                    // Push persisted comments if any
                    if let store = vm.commentStore, !store.comments.isEmpty {
                        planWebViewLoader?.setComments(key: planKey, comments: store.comments)
                    }
                }
            }

            return PermissionCardItem(id: permission.id, cardType: cardType)
        }
        currentIndex = 0
    }
}

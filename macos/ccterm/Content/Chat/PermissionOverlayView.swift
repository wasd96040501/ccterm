import SwiftUI
import AgentSDK

/// Permission card container with page dots for multiple cards.
/// Reads handle.pendingPermissions directly.
struct PermissionOverlayView: View {
    let handle: SessionHandle
    @Environment(AppViewModel.self) private var appVM
    @State private var currentIndex: Int = 0

    var body: some View {
        let permissions = handle.pendingPermissions
        VStack(spacing: 0) {
            // Fixed-height top row: page dots when multiple cards, empty spacer otherwise.
            ZStack {
                if permissions.count > 1 {
                    PageDotIndicatorSwiftUIView(count: permissions.count, currentIndex: $currentIndex)
                }
            }
            .frame(height: 16)
            .padding(.top, 2)

            if let permission = permissions[safe: currentIndex] {
                let cardType = cardType(for: permission)
                cardView(for: cardType)
                    .id(permission.id)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.35), value: currentIndex)
        .onChange(of: permissions.count) { _, newCount in
            // Clean up removed cards
            let ids = Set(permissions.map(\.id))
            for key in appVM.permissionCardTypes.keys {
                if !ids.contains(key) {
                    appVM.planRendererService.clearPlan(key: key)
                    appVM.permissionCardTypes.removeValue(forKey: key)
                }
            }
            if currentIndex >= newCount {
                currentIndex = max(0, newCount - 1)
            }
        }
    }

    private func cardType(for permission: PendingPermission) -> PermissionCardType {
        if let existing = appVM.permissionCardTypes[permission.id] {
            return existing
        }

        let cardType = PermissionCardViewModelFactory.make(
            for: permission.request,
            onDecision: { decision in permission.respond(decision) },
            onNewSession: { [weak handle] in
                guard let handle else { return }
                let plan = SessionHandle.extractPlan(from: permission.request)
                let planFilePath = SessionHandle.extractPlanFilePath(from: permission.request)
                appVM.handleRouterAction(.executePlan(PlanRequest(sourceHandle: handle, plan: plan, planFilePath: planFilePath)))
            }
        )

        if case .exitPlanMode(let vm) = cardType {
            vm.onViewPlan = { [weak handle] in
                handle?.activePlanReviewId = permission.id
                appVM.planRendererService.switchPlan(key: permission.id)
            }
            vm.onExecute = { [weak handle] mode in
                appVM.executePlanFromReview(handle: handle, mode: mode)
            }

            if let md = vm.planMarkdown, !md.isEmpty {
                let planKey = permission.id
                appVM.planRendererService.setPlan(key: planKey, markdown: md)
                vm.commentStore?.onCommentsChanged = { [weak appVM] comments in
                    appVM?.planRendererService.setComments(key: planKey, comments: comments)
                }
                if let store = vm.commentStore, !store.comments.isEmpty {
                    appVM.planRendererService.setComments(key: planKey, comments: store.comments)
                }
            }
        }

        appVM.permissionCardTypes[permission.id] = cardType
        return cardType
    }

    @ViewBuilder
    private func cardView(for cardType: PermissionCardType) -> some View {
        switch cardType {
        case .standard(let vm): StandardCardView(viewModel: vm)
        case .exitPlanMode(let vm): ExitPlanModeCardView(viewModel: vm)
        case .askUserQuestion(let vm): SwiftUIAskUserQuestionCardView(viewModel: vm)
        }
    }
}

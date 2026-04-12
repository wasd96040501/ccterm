import SwiftUI
import AgentSDK

struct PlanToolbarContent: ToolbarContent {
    @Bindable var handle: SessionHandle
    @Environment(AppViewModel.self) private var appVM

    var body: some ToolbarContent {
        // LEFT: Back button
        ToolbarItem(placement: .navigation) {
            Button {
                exitPlanReview()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13))
                }
            }
        }

        // Spacer pushes remaining items to the right
        ToolbarItem(placement: .automatic) {
            Spacer()
        }

        // RIGHT: Reject/Revise + Execute
        ToolbarItemGroup(placement: .automatic) {
            rejectReviseButton
            executeMenuButton
        }
    }

    // MARK: - Plan Card Access

    private var viewingCardVM: ExitPlanModeCardViewModel? {
        guard let reviewId = handle.activePlanReviewId,
              let cardType = appVM.permissionCardTypes[reviewId],
              case .exitPlanMode(let vm) = cardType else { return nil }
        return vm
    }

    // MARK: - Actions

    private func exitPlanReview() {
        handle.activePlanReviewId = nil
        handle.pendingCommentSelections.removeAll()
        handle.planCommentText = ""
        handle.planSearchQuery = ""
    }

    // MARK: - Reject / Revise

    private var rejectReviseButton: some View {
        let hasComments = viewingCardVM?.commentStore?.hasComments ?? false
        return Button {
            if hasComments {
                revisePlan()
            } else {
                rejectPlan()
            }
        } label: {
            Text(hasComments ? "Revise" : "Reject")
                .font(.system(size: 13))
        }
    }

    private func rejectPlan() {
        guard let vm = viewingCardVM else { return }
        let requestId = vm.request.requestId
        exitPlanReview()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        vm.executeDeny()
    }

    private func revisePlan() {
        guard let vm = viewingCardVM, let store = vm.commentStore else { return }
        let feedback = store.assembleFeedback()
        let requestId = vm.request.requestId
        exitPlanReview()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        vm.executeDenyWithFeedback(feedback)
    }

    // MARK: - Execute Menu

    private var executeMenuButton: some View {
        TintedMenuButton(
            items: [
                TintedMenuItem(
                    id: PlanExecutionMode.clearContextAutoAccept.menuId,
                    icon: "bolt.fill",
                    title: "Clear & Auto",
                    subtitle: String(localized: "Clear context and auto-accept all changes"),
                    tintColor: PermissionMode.auto.tintColor,
                    isSelected: false
                ),
                TintedMenuItem(
                    id: PlanExecutionMode.autoAcceptEdits.menuId,
                    icon: PermissionMode.acceptEdits.iconName,
                    title: "Auto Accept",
                    subtitle: String(localized: "Keep context and auto-accept file edits"),
                    tintColor: PermissionMode.acceptEdits.tintColor,
                    isSelected: false
                ),
                TintedMenuItem(
                    id: PlanExecutionMode.manualApprove.menuId,
                    icon: "hand.raised.fill",
                    title: "Manual",
                    subtitle: String(localized: "Review and approve each change individually"),
                    tintColor: PermissionMode.default.tintColor,
                    isSelected: false
                ),
            ],
            onSelect: { id in
                if let mode = PlanExecutionMode(menuId: id) {
                    executeWithConfirmation(mode)
                }
            },
            buttonStyle: .borderedProminent
        ) {
            Text("Execute")
                .font(.system(size: 13, weight: .medium))
        }
        .tint(.blue)
    }

    private func executeWithConfirmation(_ mode: PlanExecutionMode) {
        if viewingCardVM?.commentStore?.hasComments == true {
            handle.pendingExecuteMode = mode
        } else {
            appVM.executePlanFromReview(handle: handle, mode: mode)
        }
    }
}

// MARK: - PlanExecutionMode Menu ID

extension PlanExecutionMode {
    var menuId: String {
        switch self {
        case .clearContextAutoAccept: "clearContextAutoAccept"
        case .autoAcceptEdits: "autoAcceptEdits"
        case .manualApprove: "manualApprove"
        }
    }

    init?(menuId: String) {
        switch menuId {
        case "clearContextAutoAccept": self = .clearContextAutoAccept
        case "autoAcceptEdits": self = .autoAcceptEdits
        case "manualApprove": self = .manualApprove
        default: return nil
        }
    }
}

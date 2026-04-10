import SwiftUI

struct PlanToolbarContent: ToolbarContent {
    @Bindable var viewModel: PlanReviewViewModel

    var body: some ToolbarContent {
        // LEFT: Back button
        ToolbarItem(placement: .navigation) {
            Button {
                viewModel.exit()
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

    // MARK: - Reject / Revise

    private var rejectReviseButton: some View {
        let hasComments = viewModel.viewingCardVM?.commentStore?.hasComments ?? false
        return Button {
            if hasComments {
                viewModel.revisePlan()
            } else {
                viewModel.rejectPlan()
            }
        } label: {
            Text(hasComments ? "Revise" : "Reject")
                .font(.system(size: 13))
        }
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
        if viewModel.viewingCardVM?.commentStore?.hasComments == true {
            viewModel.pendingExecuteMode = mode
        } else {
            viewModel.executePlan(mode: mode)
        }
    }
}

// MARK: - PlanExecutionMode Menu ID

private extension PlanExecutionMode {
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

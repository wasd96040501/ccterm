import SwiftUI

struct ExitPlanModeCardView: View {
    @Bindable var viewModel: ExitPlanModeCardViewModel

    /// Concentric inset matching PermissionActionBar's capsuleInset.
    private let capsuleInset: CGFloat = 8

    /// Plan mode tint — matches PermissionMode.plan.tintColor.
    private let planTint = Color(nsColor: PermissionMode.plan.tintColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.hasPlan {
                // Fixed "Plan" label
                Text("Plan")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .padding(.bottom, 8)

                planCard
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
            }

            PermissionActionBar(
                actions: viewModel.hasPlan
                    ? [
                        .init(title: "Allow") { viewModel.onExecute?(.manualApprove) },
                        .init(title: "Auto Accept Edits") { viewModel.onExecute?(.autoAcceptEdits) },
                        .init(title: "Clear Context & Auto Accept", isPrimary: true) { viewModel.onExecute?(.clearContextAutoAccept) },
                    ]
                    : [.init(title: "Allow", isPrimary: true) { viewModel.confirm() }],
                onDeny: { feedback in viewModel.deny(feedback: feedback) }
            )
        }
    }

    // MARK: - Plan Card

    private var planCard: some View {
        Button {
            viewModel.onViewPlan?()
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = viewModel.planTitle {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(planTint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if let subtitle = viewModel.planSubtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 12)

                Spacer(minLength: 8)

                Text("View Plan")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(planTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(planTint.opacity(0.12), in: Capsule())
                    .padding(.trailing, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [planTint.opacity(0.06), planTint.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(planTint.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

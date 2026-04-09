import SwiftUI

struct StandardCardView: View {
    @Bindable var viewModel: StandardCardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tool content
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.toolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                ToolContentView(descriptor: viewModel.content, preloadedLoader: viewModel.webViewLoader)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            // Action bar
            PermissionActionBar(
                actions: [
                    .init(title: "Always allow") { viewModel.allowAlways() },
                    .init(title: "Allow", isPrimary: true) { viewModel.confirm() },
                ],
                onDeny: { feedback in viewModel.deny(feedback: feedback) }
            )
        }
    }
}

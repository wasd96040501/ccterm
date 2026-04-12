#if DEBUG
import SwiftUI
import AgentSDK

/// Debug gallery that tests ExitPlanMode permission cards in the exact same layout as ChatView.
struct PermissionCardLiveGalleryView: View {

    var body: some View {
        VStack(spacing: 16) {
            Text("Permission Card Live Gallery")
                .font(.title2.bold())
            Text("Use Plan Gallery from sidebar to test live permission cards")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#endif

import SwiftUI

/// 操作区入口行（新对话、新项目、Tasks、归档、Quick Chat）。
struct SidebarActionRow: View {
    let action: SidebarActionKind

    @State private var isHovered = false

    var body: some View {
        HStack {
            Label(action.title, systemImage: action.symbolName)
            Spacer()
            if action == .newConversation {
                Text("⌘N")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .hoverCapsule(staticFill: Color(nsColor: .labelColor).opacity(0.08))
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
        }
        .onHover { isHovered = $0 }
    }
}

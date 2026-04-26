import SwiftUI

/// v2 Sidebar 选中态。`.newConversation` 高亮顶部"新对话"行,`.session(id)`
/// 高亮某条历史会话。state 不在此持有 —— 由 `SessionManager2.current` derive。
enum SidebarSelection2: Hashable {
    case newConversation
    case session(String)
}

/// v2 Sidebar:顶部 action section("新对话")+ 按项目分组的扁平历史会话列表。
/// selection 单向 —— 父传入当前选中,user 点击通过 onSelect 回调驱动 manager。
struct SidebarView2: View {

    let selection: SidebarSelection2
    let onSelect: (SidebarSelection2) -> Void

    @Environment(SessionManager2.self) private var manager
    @State private var groups: [ProjectGroup2] = []

    private var listSelection: Binding<SidebarSelection2?> {
        Binding(
            get: { selection },
            set: { newValue in
                guard let newValue, newValue != selection else { return }
                onSelect(newValue)
            }
        )
    }

    var body: some View {
        List(selection: listSelection) {
            actionSection
            sessionSections
        }
        .listStyle(.sidebar)
        .task { reload() }
        .onChange(of: manager.current.sessionId) { _, _ in
            // current 切换可能因为 send → ensureStarted 写 db,reload 让新 record 出现。
            reload()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var actionSection: some View {
        Section {
            SidebarNewConversationRow()
                .tag(SidebarSelection2.newConversation)
        }
    }

    @ViewBuilder
    private var sessionSections: some View {
        ForEach(groups) { group in
            Section(group.folderName) {
                ForEach(group.records) { record in
                    SidebarRow2(record: record)
                        .tag(SidebarSelection2.session(record.sessionId))
                }
            }
        }
    }

    private func reload() {
        let records = manager.allRecords()
        let buckets = Dictionary(grouping: records) { $0.groupingFolderName ?? "Unknown" }
        groups = buckets.map { folder, items in
            ProjectGroup2(
                folderName: folder,
                records: items.sorted { $0.lastActiveAt > $1.lastActiveAt }
            )
        }
        .sorted {
            guard let a = $0.records.first, let b = $1.records.first else { return false }
            return a.lastActiveAt > b.lastActiveAt
        }
    }
}

// MARK: - Types

private struct ProjectGroup2: Identifiable {
    var id: String { folderName }
    let folderName: String
    let records: [SessionRecord]
}

// MARK: - Rows

/// 顶部"新对话"行 —— Label + ⌘N hover hint(对齐老 SidebarActionRow 风格)。
private struct SidebarNewConversationRow: View {
    @State private var isHovered = false

    var body: some View {
        HStack {
            Label(String(localized: "New Conversation"), systemImage: "square.and.pencil")
            Spacer()
            Text("⌘N")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .hoverCapsule(staticFill: Color(nsColor: .labelColor).opacity(0.08))
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .onHover { isHovered = $0 }
    }
}

private struct SidebarRow2: View {
    let record: SessionRecord

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            Text(record.title.isEmpty ? record.sessionId : record.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

import SwiftUI

/// v2 Sidebar:按项目分组的扁平历史会话列表。selection 单向 —— 父传入当前选中
/// id,user 点击通过 `onSelect` 回调驱动 `SessionManager2.select(_:)`。
///
/// 数据源直接来自 `SessionManager2.allRecords()`,按 `groupingFolderName` 分组,
/// 组内按 `lastActiveAt` 降序。`.notStarted` 的新对话 handle 不在 db 里,
/// sidebar 也不展示 —— 第一次 send 触发 ensureStarted 写 db 后,reload 才会出现。
struct SidebarView2: View {

    /// 来自 `manager.current.sessionId`,用作 `List` selection 的可视高亮。
    /// 用 `Binding` 而非 `let` 是因为 `List(selection:)` 要求 `@Binding<Hashable?>`;
    /// setter 立即 forward 到 `onSelect`,实现单向流(state 在 manager,view 只渲染)。
    let selectedSessionId: String
    let onSelect: (String) -> Void

    @Environment(SessionManager2.self) private var manager
    @State private var groups: [ProjectGroup2] = []

    private var listSelection: Binding<String?> {
        Binding(
            get: { selectedSessionId },
            set: { newValue in
                guard let id = newValue, id != selectedSessionId else { return }
                onSelect(id)
            }
        )
    }

    var body: some View {
        List(selection: listSelection) {
            ForEach(groups) { group in
                Section(group.folderName) {
                    ForEach(group.records) { record in
                        SidebarRow2(record: record)
                            .tag(record.sessionId)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task { reload() }
        .onChange(of: manager.current.sessionId) { _, _ in
            // current 切换可能因为 send → ensureStarted 写 db,reload 让新 record 出现。
            reload()
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

// MARK: - Row

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

import SwiftUI

/// v2 Sidebar：按项目分组的扁平历史会话列表。只读浏览用，无 running / pinned / archive / unread。
///
/// 数据源直接来自 `SessionManager2.allRecords()`，按 `groupingFolderName` 分组，
/// 组内按 `lastActiveAt` 降序。
struct SidebarView2: View {
    @Binding var selection: String?
    @Environment(SessionManager2.self) private var manager
    @State private var groups: [ProjectGroup2] = []

    /// Sentinel selection value used by the dev-only Transcript Demo tab.
    /// Reserved by the double-underscore prefix; real session IDs are UUIDs.
    static let transcriptDemoTag = "__transcript_demo__"

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Transcript Demo", systemImage: "doc.text.image")
                    .tag(Self.transcriptDemoTag)
            }
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

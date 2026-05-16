import SwiftUI

/// Sidebar: flat history list of sessions grouped by project. Read-only — no
/// running / pinned / archive / unread state.
///
/// Sourced directly from `SessionManager2.records`, grouped by
/// `groupingFolderName`, sorted by `lastActiveAt` descending within each group.
struct SidebarView2: View {
    @Binding var selection: String?
    @Environment(SessionManager2.self) private var manager

    /// Sentinel selection value for the "New Session" tab.
    static let newSessionTag = "__new_session__"
    /// Sentinel selection value used by the dev-only Transcript Demo tab.
    /// Reserved by the double-underscore prefix; real session IDs are UUIDs.
    static let transcriptDemoTag = "__transcript_demo__"
    /// Sentinel for the Transcript Stress tab (long-document perf test).
    static let transcriptStressTag = "__transcript_stress__"

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("New Session", systemImage: "square.and.pencil")
                    .tag(Self.newSessionTag)
                Label("Transcript Demo", systemImage: "doc.text.image")
                    .tag(Self.transcriptDemoTag)
                Label("Transcript Stress", systemImage: "speedometer")
                    .tag(Self.transcriptStressTag)
            }
            ForEach(groupedRecords) { group in
                Section(group.folderName) {
                    ForEach(group.records) { record in
                        SidebarRow2(record: record)
                            .tag(record.sessionId)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Grouped list derived from `manager.records`. Computed reads the
    /// observable directly, so updates recompute automatically without manual reload.
    private var groupedRecords: [ProjectGroup2] {
        let buckets = Dictionary(grouping: manager.records) { $0.groupingFolderName ?? "Unknown" }
        return buckets.map { folder, items in
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

private struct ProjectGroup2: Identifiable {
    var id: String { folderName }
    let folderName: String
    let records: [SessionRecord]
}

private struct SidebarRow2: View {
    let record: SessionRecord

    var body: some View {
        Text(record.title.isEmpty ? record.sessionId : record.title)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

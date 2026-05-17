import SwiftUI

/// Sidebar: a fixed top group of utility items (New Session, demos) plus
/// folder-grouped history below. Sourced directly from `SessionManager2.records`,
/// grouped by `groupingFolderName`, sorted by `lastActiveAt` descending.
///
/// Component tree (intentionally flat — no `Section` wrappers, no
/// `DisclosureGroup`, so all rows share a single leading column and
/// align icon-to-icon / text-to-text):
///
/// ```
/// List(selection)
/// ├── SidebarItemRow × N      (fixed top items, icon + text)
/// └── ForEach(folders)
///     ├── SidebarFolderHeader (folder icon + dim text + chevron)
///     └── if expanded { ForEach(records) SidebarHistoryRow }
/// ```
///
/// Three row types — `SidebarItemRow`, `SidebarFolderHeader`,
/// `SidebarHistoryRow` — all share the same `SidebarIcon` slot frame, so
/// the leading icon column lines up across the entire list. History rows
/// pass `nil` as the system image to render a transparent placeholder
/// (text aligns with the folder header's text above).
struct SidebarView2: View {
    @Binding var selection: String?
    @Environment(SessionManager2.self) private var manager
    /// Folders the user has manually collapsed. Default is expanded; we
    /// track collapsed-set rather than expanded-set so newly-appearing
    /// folders (after a fresh session lands) are open by default.
    @State private var collapsedFolders: Set<String> = []

    /// Sentinel selection value for the "New Session" tab.
    static let newSessionTag = "__new_session__"
    /// Sentinel selection value used by the dev-only Transcript Demo tab.
    /// Reserved by the double-underscore prefix; real session IDs are UUIDs.
    static let transcriptDemoTag = "__transcript_demo__"
    /// Sentinel for the Transcript Stress tab (long-document perf test).
    static let transcriptStressTag = "__transcript_stress__"

    var body: some View {
        List(selection: $selection) {
            SidebarItemRow(title: "New Session", systemImage: "square.and.pencil")
                .tag(Self.newSessionTag)
                .listRowInsets(Self.fixedRowInsets)
            SidebarItemRow(title: "Transcript Demo", systemImage: "doc.text.image")
                .tag(Self.transcriptDemoTag)
                .listRowInsets(Self.fixedRowInsets)
            SidebarItemRow(title: "Transcript Stress", systemImage: "speedometer")
                .tag(Self.transcriptStressTag)
                .listRowInsets(Self.fixedRowInsets)

            ForEach(groupedRecords) { group in
                SidebarFolderHeader(
                    name: group.folderName,
                    isExpanded: !collapsedFolders.contains(group.folderName),
                    onToggle: { toggleFolder(group.folderName) }
                )
                .listRowInsets(Self.folderHeaderInsets)
                .selectionDisabled()

                if !collapsedFolders.contains(group.folderName) {
                    ForEach(group.records) { record in
                        SidebarHistoryRow(record: record)
                            .tag(record.sessionId)
                            .listRowInsets(Self.historyRowInsets)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
    }

    /// Shared horizontal insets keep the icon column aligned across all
    /// three row types; vertical insets differ to give history rows a
    /// tighter rhythm without shrinking the font.
    private static let fixedRowInsets = EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 8)
    private static let folderHeaderInsets = EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 8)
    private static let historyRowInsets = EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 8)

    private func toggleFolder(_ name: String) {
        withAnimation(.smooth(duration: 0.25)) {
            if collapsedFolders.contains(name) {
                collapsedFolders.remove(name)
            } else {
                collapsedFolders.insert(name)
            }
        }
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

// MARK: - Atoms

/// Fixed-frame icon slot shared by every sidebar row. Renders the named
/// SF Symbol when present, or an empty (transparent) frame when nil —
/// the latter lets history rows reserve the same horizontal column as
/// rows that do have an icon, so their text lines up with the folder
/// header's text above.
private struct SidebarIcon: View {
    static let slotWidth: CGFloat = 16
    let systemImage: String?

    var body: some View {
        ZStack {
            if let name = systemImage {
                Image(systemName: name)
                    .font(.system(size: 12, weight: .regular))
            }
        }
        .frame(width: Self.slotWidth, height: Self.slotWidth)
    }
}

// MARK: - Rows

/// Fixed top-of-sidebar entry (New Session, Transcript Demo, ...). Behaves
/// like a normal selectable List row; its `.tag` is supplied by the caller.
private struct SidebarItemRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            SidebarIcon(systemImage: systemImage)
            Text(title)
        }
        .lineLimit(1)
    }
}

/// Folder-grouping header row. Same row chrome as `SidebarItemRow` (so
/// icons + text align), but the whole row is rendered in the secondary
/// foreground to read as a section label rather than a destination. Tap
/// anywhere on the row to collapse / expand — the chevron rotates and
/// the children inside the surrounding `ForEach` animate in/out.
private struct SidebarFolderHeader: View {
    let name: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                SidebarIcon(systemImage: "folder")
                Text(name)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
}

/// History entry inside a folder group. No leading icon — `SidebarIcon`
/// is invoked with `nil` to reserve the icon column as transparent
/// padding, so the title text aligns with the folder header's text
/// above. Empty titles render as a faint italic "Untitled" placeholder.
private struct SidebarHistoryRow: View {
    let record: SessionRecord

    var body: some View {
        HStack(spacing: 6) {
            SidebarIcon(systemImage: nil)
            Group {
                if record.title.isEmpty {
                    Text("Untitled")
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(record.title)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }
}

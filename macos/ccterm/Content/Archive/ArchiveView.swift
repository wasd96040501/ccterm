import SwiftUI

/// Read-only browser for soft-deleted sessions, opened from the sidebar's
/// "Archive" item. The list is sourced from
/// `SessionManager.archivedRecords` — a lazily-populated observable
/// snapshot that's refreshed on appear and after every archive /
/// unarchive operation, so changes made while the page is visible
/// (e.g. unarchive a row, archive a different session from elsewhere)
/// land immediately.
///
/// Component tree (intentionally flat — no `Form`, no `List` chrome, so
/// the page reads as a clean column rather than a settings sheet):
///
/// ```
/// ArchiveView (NavigationStack content)
/// ├── Header (title only — leading-aligned with row text column)
/// └── ScrollView
///     └── LazyVStack(spacing: 0)
///         ├── if filteredRecords.isEmpty → EmptyState / NoMatchState
///         └── else ForEach(records) {
///                 ArchiveRow
///                 + Divider (between rows, never trailing)
///             }
/// ```
///
/// Window toolbar:
/// - `.searchable` for matching title / worktree branch (system search
///   field, same chrome as the chat-history one).
/// - A folder-filter button that opens `FolderFilterPickerView` in a
///   popover. Filtering is in-memory over the already-fetched archived
///   list, so there's no DB-side index work — the dataset is bounded by
///   how many sessions the user has archived, typically dozens.
///
/// Width policy:
/// - Min width 480pt — matches the chat detail's `minWidth: 400` plus a
///   bit of safety so the row's two-column layout (text / action) never
///   has to clip.
/// - Max width 760pt — wider than the compose card (680pt) so archived
///   titles have a bit more breathing room without the column feeling
///   over-stretched on big windows. Centered horizontally so a 1600pt
///   window doesn't smear the column to either edge.
struct ArchiveView: View {
    @Environment(SessionManager.self) private var manager

    /// Caller-supplied unarchive sink so selection can hop back to the
    /// restored session in `RootView2`. Receives the restored
    /// `sessionId`; nil for the empty-state preview path.
    let onUnarchive: ((String) -> Void)?

    @State private var searchQuery: String = ""
    /// `nil` means "All Folders"; otherwise the canonical
    /// `record.groupingPath` to match against.
    @State private var selectedFolderPath: String? = nil
    @State private var isFilterPopoverPresented: Bool = false

    init(onUnarchive: ((String) -> Void)? = nil) {
        self.onUnarchive = onUnarchive
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                bodyContent
                Spacer(minLength: 24)
            }
            .frame(
                minWidth: Self.columnMinWidth,
                maxWidth: Self.columnMaxWidth
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(
            text: $searchQuery,
            placement: .toolbar,
            prompt: Text("Search archived sessions")
        )
        .toolbar {
            ToolbarItem(placement: .automatic) {
                filterButton
            }
        }
        .task { manager.refreshArchivedRecords() }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if manager.archivedRecords.isEmpty {
            ArchiveEmptyState()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            let records = filteredRecords
            if records.isEmpty {
                ArchiveNoMatchState()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        ArchiveRow(
                            record: record,
                            onUnarchive: { unarchive(record) }
                        )
                        if index < records.count - 1 {
                            Divider()
                                .padding(.leading, Self.rowHorizontalPadding)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    /// Header sits at the same leading inset as the row text column —
    /// matches `ArchiveRow`'s `rowHorizontalPadding` so the "Archive"
    /// title baseline and the first row's title share a vertical line.
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Archive")
                .font(.system(size: 22, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.top, 40)
        .padding(.bottom, 16)
    }

    private var filterButton: some View {
        Button {
            isFilterPopoverPresented.toggle()
        } label: {
            Image(
                systemName: selectedFolderPath == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .help(Text("Filter by folder"))
        .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .top) {
            FolderFilterPickerView(
                folders: folderOptions,
                selectedPath: selectedFolderPath,
                onSelect: { path in
                    selectedFolderPath = path
                    isFilterPopoverPresented = false
                }
            )
        }
    }

    /// Distinct folder options drawn from the full archived list (not the
    /// post-filter view), so the picker doesn't shrink as the user narrows
    /// the search field. Records without a `groupingPath` are dropped —
    /// they couldn't be folder-filtered anyway. Sorted alphabetically by
    /// name for predictable scanning.
    private var folderOptions: [FolderFilterPickerView.Folder] {
        let buckets = Dictionary(grouping: manager.archivedRecords) { $0.groupingPath }
        return buckets.compactMap { path, records -> FolderFilterPickerView.Folder? in
            guard let path, !path.isEmpty, let first = records.first else { return nil }
            let name = first.groupingFolderName ?? path
            return FolderFilterPickerView.Folder(path: path, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Records after applying the in-memory folder and text filters.
    /// Folder filter matches `groupingPath`; text filter matches the
    /// title or `worktreeBranch` (case-insensitive substring on both).
    private var filteredRecords: [SessionRecord] {
        var records = manager.archivedRecords
        if let path = selectedFolderPath {
            records = records.filter { ($0.groupingPath ?? "") == path }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            records = records.filter { record in
                if record.title.localizedCaseInsensitiveContains(q) { return true }
                if let branch = record.worktreeBranch, branch.localizedCaseInsensitiveContains(q) {
                    return true
                }
                return false
            }
        }
        return records
    }

    private func unarchive(_ record: SessionRecord) {
        let sid = record.sessionId
        withAnimation(.smooth(duration: 0.25)) {
            manager.unarchive(sid)
        }
        onUnarchive?(sid)
    }

    fileprivate static let columnMinWidth: CGFloat = 480
    fileprivate static let columnMaxWidth: CGFloat = 760
    fileprivate static let rowHorizontalPadding: CGFloat = 12
}

// MARK: - Row

/// One archived session. Two-line text column on the left (title +
/// metadata strip), single trailing "Unarchive" pill on the right.
///
/// Internal access so the snapshot test can compose the row in
/// isolation; see `ArchiveViewSnapshotTests`.
struct ArchiveRow: View {
    let record: SessionRecord
    let onUnarchive: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            textColumn
            Spacer(minLength: 8)
            unarchiveButton
        }
        .padding(.horizontal, ArchiveView.rowHorizontalPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText
                .lineLimit(1)
                .truncationMode(.middle)
            metadataStrip
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var titleText: some View {
        if record.title.isEmpty || record.title == "[unknown session]" {
            Text("Untitled")
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(.secondary)
        } else {
            Text(record.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
        }
    }

    /// Folder + (optional) worktree branch + archived-relative date.
    /// The folder slot always renders with the `folder` SF Symbol — the
    /// branch slot is what distinguishes a worktree row, rendered with
    /// `arrow.triangle.branch` only when `isWorktree` and a branch name
    /// is on hand.
    private var metadataStrip: some View {
        HStack(spacing: 6) {
            if let folder = folderLabel {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: "·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if record.isWorktree, let branch = record.worktreeBranch, !branch.isEmpty {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(branch)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: "·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(archivedRelative)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var unarchiveButton: some View {
        Button(action: onUnarchive) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Unarchive")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(HoverCapsuleStyle(hoverOpacity: 0.10, pressOpacity: 0.18))
        .help(Text("Unarchive"))
    }

    private var folderLabel: String? {
        record.groupingFolderName
    }

    /// Human-readable "archived" timestamp. We deliberately surface only
    /// one time anchor (archived-at) rather than archived-at + last-active
    /// — for an archived row the only thing the user cares about is when
    /// it dropped off the main list. "Archived just now" / "Archived 3
    /// days ago" puts that one bit front and center.
    private var archivedRelative: String {
        let date = record.archivedAt ?? record.lastActiveAt
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let phrase = formatter.localizedString(for: date, relativeTo: Date())
        return String(localized: "Archived \(phrase)")
    }
}

// MARK: - Empty / No-match state

/// Centered message when nothing has been archived yet. The icon mirrors
/// the sidebar entry so visual continuity holds when the user lands on
/// the page for the first time.
private struct ArchiveEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No archived sessions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Archive a session from its right-click menu in the sidebar.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }
}

/// Centered message when the archive list is non-empty but the active
/// search / folder filter excludes every row. Distinct from
/// `ArchiveEmptyState` so the user knows the data is there — just hidden
/// by the current query.
private struct ArchiveNoMatchState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No matching sessions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Try clearing the search or folder filter.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }
}

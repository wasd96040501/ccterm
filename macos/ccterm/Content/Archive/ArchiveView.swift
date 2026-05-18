import SwiftUI

/// Read-only browser for soft-deleted sessions, opened from the sidebar's
/// "Archive" item. The list is sourced from
/// `SessionManager2.archivedRecords` — a lazily-populated observable
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
/// ├── Header (title + count chip)
/// └── ScrollView
///     └── LazyVStack(spacing: 0)
///         ├── if archivedRecords.isEmpty → EmptyState
///         └── else ForEach(records) {
///                 ArchiveRow
///                 + Divider (between rows, never trailing)
///             }
/// ```
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
    @Environment(SessionManager2.self) private var manager

    /// Caller-supplied unarchive sink so selection can hop back to the
    /// restored session in `RootView2`. Receives the restored
    /// `sessionId`; nil for the empty-state preview path.
    let onUnarchive: ((String) -> Void)?

    init(onUnarchive: ((String) -> Void)? = nil) {
        self.onUnarchive = onUnarchive
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if manager.archivedRecords.isEmpty {
                    ArchiveEmptyState()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(manager.archivedRecords.enumerated()), id: \.element.id) { index, record in
                            ArchiveRow(
                                record: record,
                                onUnarchive: { unarchive(record) }
                            )
                            if index < manager.archivedRecords.count - 1 {
                                Divider()
                                    .padding(.leading, Self.rowHorizontalPadding)
                            }
                        }
                    }
                    .padding(.top, 12)
                }
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
        .task { manager.refreshArchivedRecords() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Archive")
                .font(.system(size: 22, weight: .semibold))
            if !manager.archivedRecords.isEmpty {
                Text(verbatim: "\(manager.archivedRecords.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color(nsColor: .labelColor).opacity(0.06))
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 40)
        .padding(.bottom, 16)
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

    private var metadataStrip: some View {
        HStack(spacing: 6) {
            if let folder = folderLabel {
                Image(systemName: record.isWorktree ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(folder)
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

// MARK: - Empty state

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

import SwiftUI

/// Popover picker for choosing a single folder filter (or "All Folders").
/// Modeled after `BranchPickerView`: a top search field over a scrolling
/// list of rows, each row showing the folder name as the title and the
/// full path as a `truncationMode(.middle)` subtitle. A leading "All
/// Folders" row clears the filter.
///
/// The picker is intentionally folder-shaped (name + path subtitle)
/// rather than fully generic — callers pass `[Folder]` directly. If a
/// second site grows the same shape, lift this into a generic
/// `title + subtitle` picker.
struct FolderFilterPickerView: View {

    /// A single folder entry. `path` is the canonical identity (the
    /// caller's groupingPath); `name` is the leaf displayed as the row
    /// title. Two folders with the same leaf but different paths are
    /// distinct rows.
    struct Folder: Identifiable, Hashable {
        let path: String
        let name: String

        var id: String { path }
    }

    let folders: [Folder]
    /// Currently-active folder filter, by `path`. nil means "All Folders".
    let selectedPath: String?
    /// Invoked with the new selection — `nil` for "All Folders", otherwise
    /// the row's `path`. The caller is responsible for dismissing the
    /// popover.
    let onSelect: (String?) -> Void

    @State private var searchText = ""

    private var filteredFolders: [Folder] {
        if searchText.isEmpty { return folders }
        return folders.filter { folder in
            folder.name.localizedCaseInsensitiveContains(searchText)
                || folder.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchSection
            folderListSection
        }
        .frame(width: 320)
    }

    private var searchSection: some View {
        SearchField(text: $searchText, placeholder: String(localized: "Search folders…"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var folderListSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if searchText.isEmpty {
                    FolderRow(
                        name: String(localized: "All Folders"),
                        path: nil,
                        isSelected: selectedPath == nil,
                        onTap: { onSelect(nil) }
                    )
                    if !filteredFolders.isEmpty {
                        Divider()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
                if filteredFolders.isEmpty && !searchText.isEmpty {
                    emptyView
                } else {
                    ForEach(filteredFolders) { folder in
                        FolderRow(
                            name: folder.name,
                            path: folder.path,
                            isSelected: folder.path == selectedPath,
                            onTap: { onSelect(folder.path) }
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 240, alignment: .top)
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No Matching Folders")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - FolderRow

private struct FolderRow: View {

    let name: String
    /// `nil` for the "All Folders" sentinel; otherwise the trim-middle
    /// path subtitle.
    let path: String?
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 12, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    if let path, !path.isEmpty {
                        Text(path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

private struct FolderFilterPickerPreviewWrapper: View {
    @State private var showPopover = false
    @State private var selectedPath: String? = nil

    var body: some View {
        Button("Filter folders") {
            showPopover = true
        }
        .popover(isPresented: $showPopover) {
            FolderFilterPickerView(
                folders: [
                    .init(path: "/Users/me/work/project-a", name: "project-a"),
                    .init(path: "/Users/me/work/project-b", name: "project-b"),
                    .init(
                        path: "/Users/me/long/nested/path/to/some/deeply/buried/project-c",
                        name: "project-c"),
                ],
                selectedPath: selectedPath,
                onSelect: { path in
                    selectedPath = path
                    showPopover = false
                }
            )
        }
    }
}

#Preview {
    FolderFilterPickerPreviewWrapper()
        .frame(width: 360, height: 200)
}

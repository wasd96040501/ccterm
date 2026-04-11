import SwiftUI
import AppKit

enum FolderPickerMode {
    case singleSelect
    case multiSelect
    case singleAndMultiSelect
}

struct FolderPickerPopover: View {

    let title: String
    let description: String
    var mode: FolderPickerMode = .singleAndMultiSelect
    let loadFoldersAction: () -> [URL]
    let saveFoldersAction: ([URL]) -> Void
    let onConfirm: (_ primary: URL?, _ additional: [URL]) -> Void

    var readOnly: Bool = false
    var primaryReadOnly: Bool = false
    var initialPrimary: URL? = nil
    var initialAdditional: Set<URL> = []

    /// Convenience initializer: uses UserDefaults for persistence
    init(title: String, description: String, userDefaultsKey: String,
         mode: FolderPickerMode = .singleAndMultiSelect,
         readOnly: Bool = false,
         primaryReadOnly: Bool = false,
         initialPrimary: URL? = nil,
         initialAdditional: Set<URL> = [],
         onConfirm: @escaping (_ primary: URL?, _ additional: [URL]) -> Void) {
        self.title = title
        self.description = description
        self.mode = mode
        self.readOnly = readOnly
        self.primaryReadOnly = primaryReadOnly
        self.initialPrimary = initialPrimary
        self.initialAdditional = initialAdditional
        self.loadFoldersAction = {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return paths.map { URL(fileURLWithPath: $0) }
        }
        self.saveFoldersAction = { urls in
            if let data = try? JSONEncoder().encode(urls.map(\.path)) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        }
        self.onConfirm = onConfirm
    }

    /// Generic initializer: caller provides load/save closures
    init(title: String, description: String, mode: FolderPickerMode = .singleAndMultiSelect,
         readOnly: Bool = false,
         primaryReadOnly: Bool = false,
         initialPrimary: URL? = nil,
         initialAdditional: Set<URL> = [],
         loadFolders: @escaping () -> [URL], saveFolders: @escaping ([URL]) -> Void,
         onConfirm: @escaping (_ primary: URL?, _ additional: [URL]) -> Void) {
        self.title = title
        self.description = description
        self.mode = mode
        self.readOnly = readOnly
        self.primaryReadOnly = primaryReadOnly
        self.initialPrimary = initialPrimary
        self.initialAdditional = initialAdditional
        self.loadFoldersAction = loadFolders
        self.saveFoldersAction = saveFolders
        self.onConfirm = onConfirm
    }

    @State private var folders: [URL] = []
    @State private var selectedPrimary: URL?
    @State private var selectedAdditional: Set<URL> = []
    @State private var searchText = ""
    private var filteredFolders: [URL] {
        if searchText.isEmpty { return folders }
        return folders.filter {
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Detects if `searchText` is an absolute path pointing to an existing directory not yet in the list.
    private var detectedDirectoryURL: URL? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let url = URL(fileURLWithPath: expanded)
        guard !folders.contains(url) else { return nil }
        return url
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            searchSection
            if mode != .multiSelect {
                Divider()
                primarySection
            }
            if mode != .singleSelect {
                Divider()
                additionalSection
            }
            Divider()
            bottomBar
        }
        .frame(width: 300)
        .onAppear(perform: loadFolders)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Search

    private var searchSection: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, placeholder: String(localized: "Search folders…"))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onSubmit {
                    if detectedDirectoryURL != nil {
                        addDetectedDirectory()
                    }
                }
            if let url = detectedDirectoryURL {
                Button(action: addDetectedDirectory) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        Text("Add \"\(url.lastPathComponent)\"")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(url.path)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Primary

    private let listHeight: CGFloat = 120

    /// primary 是否锁定（readOnly 全锁 或 primaryReadOnly 单锁）
    private var isPrimaryLocked: Bool { readOnly || primaryReadOnly }

    private var primarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "Primary Directory"))

            if isPrimaryLocked, let primary = selectedPrimary {
                // 紧凑只读：仅展示当前 primary 单行
                FolderRow(
                    url: primary,
                    isSelected: true,
                    onTap: {},
                    onDoubleTap: {}
                )
            } else if filteredFolders.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredFolders, id: \.self) { folder in
                            FolderRow(
                                url: folder,
                                isSelected: folder == selectedPrimary,
                                onTap: { selectedPrimary = folder },
                                onDoubleTap: {
                                    selectedPrimary = folder
                                    confirm()
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(height: isPrimaryLocked ? nil : listHeight, alignment: .top)
    }

    // MARK: - Additional

    private var additionalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "Additional Dirs (\(selectedAdditional.count))"))

            if filteredFolders.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredFolders, id: \.self) { folder in
                            AdditionalFolderRow(
                                url: folder,
                                isSelected: selectedAdditional.contains(folder),
                                onToggle: readOnly ? {} : {
                                    if selectedAdditional.contains(folder) {
                                        selectedAdditional.remove(folder)
                                    } else {
                                        selectedAdditional.insert(folder)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(height: listHeight, alignment: .top)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if !readOnly {
                Button(action: addFolders) {
                    Image(systemName: "plus")
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Add folders"))

                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canRemove)
                .help(String(localized: "Remove selected folder"))
            }

            Spacer()

            Button(readOnly ? String(localized: "Done") : String(localized: "Confirm")) {
                confirm()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!readOnly && !isPrimaryLocked && mode != .multiSelect && selectedPrimary == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 4) {
            Image(systemName: "folder.badge.plus")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Click + to add folders")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed

    private var canRemove: Bool {
        (!isPrimaryLocked && selectedPrimary != nil) || !selectedAdditional.isEmpty
    }

    // MARK: - Actions

    private func confirm() {
        switch mode {
        case .multiSelect:
            onConfirm(nil, Array(selectedAdditional))
        case .singleSelect:
            guard let primary = selectedPrimary else { return }
            onConfirm(primary, [])
        case .singleAndMultiSelect:
            guard let primary = selectedPrimary else { return }
            let additional = Array(selectedAdditional.filter { $0 != primary })
            onConfirm(primary, additional)
        }
    }

    private func addDetectedDirectory() {
        guard let url = detectedDirectoryURL else { return }
        folders.insert(url, at: 0)
        if mode == .multiSelect || mode == .singleAndMultiSelect {
            selectedAdditional.insert(url)
        }
        if mode == .singleSelect || (mode == .singleAndMultiSelect && selectedPrimary == nil) {
            selectedPrimary = url
        }
        saveFolders()
        searchText = ""
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Select folders to add")

        guard panel.runModal() == .OK else { return }

        let newURLs = panel.urls.filter { !folders.contains($0) }
        guard !newURLs.isEmpty else { return }
        folders.insert(contentsOf: newURLs, at: 0)
        selectedAdditional.formUnion(newURLs)
        saveFolders()
    }

    private func removeSelected() {
        var toRemove = selectedAdditional
        if !isPrimaryLocked, let primary = selectedPrimary {
            toRemove.insert(primary)
        }
        folders.removeAll { toRemove.contains($0) }
        if !isPrimaryLocked {
            selectedPrimary = nil
        }
        selectedAdditional.subtract(toRemove)
        saveFolders()
    }

    // MARK: - Persistence

    private func loadFolders() {
        folders = loadFoldersAction()
        if let initial = initialPrimary {
            if !folders.contains(initial) {
                folders.insert(initial, at: 0)
            }
            selectedPrimary = initial
        }
        selectedAdditional = initialAdditional.filter { folders.contains($0) }
    }

    private func saveFolders() {
        saveFoldersAction(folders)
    }
}

// MARK: - FolderRow (Primary, single-select)

private struct FolderRow: View {

    let url: URL
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(url.pathComponents.suffix(2).joined(separator: "/"))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleTap))
        .onHover { isHovered = $0 }
    }
}

// MARK: - AdditionalFolderRow (multi-select)

private struct AdditionalFolderRow: View {

    let url: URL
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(url.pathComponents.suffix(2).joined(separator: "/"))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
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

#Preview("FolderPickerPopover") {
    struct PreviewWrapper: View {
        @State private var showPopover = false

        private let previewKey = "preview.folderPicker"

        var body: some View {
            Button("Select Folder") {
                showPopover = true
            }
            .popover(isPresented: $showPopover) {
                FolderPickerPopover(
                    title: "Select Directory",
                    description: "Choose a primary directory and optional additional dirs",
                    userDefaultsKey: previewKey,
                    onConfirm: { primary, additional in
                        appLog(.debug, "FolderPickerPopover", "Primary: \(primary?.path ?? "nil")")
                        appLog(.debug, "FolderPickerPopover", "Additional: \(additional.map(\.path))")
                        showPopover = false
                    }
                )
            }
            .frame(width: 300, height: 200)
            .onAppear(perform: seedFolders)
        }

        private func seedFolders() {
            let paths = [
                "/Users/username/Documents/GitHub/ccterm",
                "/Users/username/Documents/GitHub",
                "/Users/username/Projects/demo-app",
                "/tmp/test-workspace",
            ]
            if let data = try? JSONEncoder().encode(paths) {
                UserDefaults.standard.set(data, forKey: previewKey)
            }
        }
    }
    return PreviewWrapper()
}

import AppKit
import SwiftUI

/// "Compose" card shown above the input bar on the New Session tab. Two
/// columns separated by a vertical divider, mirroring Xcode's welcome
/// window:
///
/// - **Left**: large folder icon, "Start Building" title, the chosen
///   folder's name (acts as the folder picker trigger), and a row with
///   the source-branch picker and a Worktree checkbox. The branch picker
///   and the worktree toggle disable themselves when the chosen folder
///   is not a git repository.
/// - **Right**: a sidebar-styled list of recent project folders derived
///   from `SessionManager2.records` (unique by `groupingPath`). Selecting
///   one writes back through `folderPath`. Empty state directs the user
///   to the `+` button in the top-right header.
///
/// State for the chosen folder / branch / worktree flag is owned by the
/// caller (RootView2) so the same values feed straight into the submit
/// path — this view holds only derived caches (git probe results, recent
/// list).
struct NewSessionConfigurator: View {
    @Binding var folderPath: String?
    @Binding var useWorktree: Bool
    @Binding var sourceBranch: String?

    /// Fixed visual height; the parent assumes this when computing the
    /// compose-mode vertical centering padding.
    static let height: CGFloat = 200
    /// Right-column width. Left column takes the rest minus a 1pt divider.
    private static let recentColumnWidth: CGFloat = 240

    @Environment(SessionManager2.self) private var manager
    @State private var branches: [String] = []
    @State private var currentBranch: String? = nil
    @State private var isGitRepo: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
            Divider()
            rightPanel
                .frame(width: Self.recentColumnWidth, alignment: .top)
                .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .barSurface(cornerRadius: 16)
        .testIdentifier("NewSession.Card")
        .onChange(of: folderPath) { _, _ in refreshGitInfo() }
        .task { refreshGitInfo() }
    }

    // MARK: - Left panel

    @ViewBuilder
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: folderPath == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56, alignment: .center)

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Start Building"))
                        .font(.system(size: 18, weight: .semibold))

                    Button(action: presentFolderPicker) {
                        HStack(spacing: 4) {
                            Text(
                                folderPath.map { ($0 as NSString).lastPathComponent }
                                    ?? String(localized: "Choose Folder…")
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(folderPath == nil ? Color.secondary : Color.primary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .testIdentifier("NewSession.FolderPicker")
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                branchPicker
                Toggle(isOn: $useWorktree) {
                    Text(String(localized: "Worktree"))
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!isGitRepo)
                .testIdentifier("NewSession.WorktreeToggle")
            }
        }
    }

    @ViewBuilder
    private var branchPicker: some View {
        let displayBranch = sourceBranch ?? currentBranch ?? String(localized: "(no branch)")
        Menu {
            ForEach(branches, id: \.self) { name in
                Button(action: { sourceBranch = name }) {
                    if name == sourceBranch || (sourceBranch == nil && name == currentBranch) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                Text(displayBranch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 180)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isGitRepo)
        .testIdentifier("NewSession.BranchPicker")
    }

    // MARK: - Right panel (recents)

    @ViewBuilder
    private var rightPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Recent"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: presentFolderPicker) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Choose Folder…"))
                .testIdentifier("NewSession.AddRecent")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if recents.isEmpty {
                emptyRecents
            } else {
                recentsList
            }
        }
    }

    @ViewBuilder
    private var emptyRecents: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(String(localized: "No recent projects"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(String(localized: "Tap + above to add one"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var recentsList: some View {
        // `List(selection:)` gives us the native sidebar selection
        // highlight at no cost; binding selection back to `folderPath`
        // means picking a row is a single round-trip into the same
        // state RootView2 reads at submit time.
        List(selection: folderPathSelection) {
            ForEach(recents) { entry in
                recentRow(entry)
                    .tag(entry.path as String?)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .testIdentifier("NewSession.RecentList")
    }

    /// Wrap the binding so the row's `tag` (an optional path) can drive
    /// `folderPath` without nilling it when the system clears selection
    /// during list rebuilds.
    private var folderPathSelection: Binding<String?> {
        Binding(
            get: { folderPath },
            set: { new in
                if let new { folderPath = new }
            }
        )
    }

    @ViewBuilder
    private func recentRow(_ entry: RecentFolder) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text(entry.path)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Recents derivation

    private struct RecentFolder: Hashable, Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let lastActive: Date
    }

    /// One row per unique `groupingPath`, sorted by the most recent
    /// `lastActiveAt` in that group. Capped to keep the list a short
    /// pick-from-recents rather than a second sidebar.
    private var recents: [RecentFolder] {
        var seen = Set<String>()
        var out: [RecentFolder] = []
        for record in manager.records {
            guard let path = record.groupingPath else { continue }
            if seen.insert(path).inserted {
                let name = (path as NSString).lastPathComponent
                out.append(
                    RecentFolder(path: path, name: name, lastActive: record.lastActiveAt))
            }
            if out.count >= 20 { break }
        }
        return out
    }

    // MARK: - Folder picker

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder for the new session")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            folderPath = url.path
        }
    }

    // MARK: - Git probing

    /// Cache `isGitRepo` / `currentBranch` / `branches` for the picked
    /// folder. Called once on appear and whenever `folderPath` changes.
    /// All git calls are short, synchronous, and bounded by `runGit`'s
    /// timeout — invoking them on the main actor is fine for a one-shot
    /// directory probe.
    private func refreshGitInfo() {
        guard let path = folderPath else {
            isGitRepo = false
            branches = []
            currentBranch = nil
            useWorktree = false
            sourceBranch = nil
            return
        }
        isGitRepo = GitUtils.isGitRepository(at: path)
        if isGitRepo {
            currentBranch = GitUtils.currentBranch(at: path)
            branches = Self.listBranches(at: path)
            if sourceBranch == nil || !branches.contains(sourceBranch ?? "") {
                sourceBranch = currentBranch
            }
        } else {
            useWorktree = false
            sourceBranch = nil
            currentBranch = nil
            branches = []
        }
    }

    private static func listBranches(at path: String) -> [String] {
        let result = Worktree.runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            cwd: path,
            timeout: 5
        )
        guard result.exitCode == 0, let stdout = result.stdout else { return [] }
        return
            stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    @Previewable @State var folder: String? = nil
    @Previewable @State var useWorktree: Bool = false
    @Previewable @State var sourceBranch: String? = nil

    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        NewSessionConfigurator(
            folderPath: $folder,
            useWorktree: $useWorktree,
            sourceBranch: $sourceBranch
        )
        .frame(width: 544)
        .padding(40)
    }
    .frame(width: 720, height: 360)
    .environment(SessionManager2())
}

import AppKit
import SwiftUI

/// "Compose" card shown above the input bar on the New Session tab. Two
/// columns separated by a vertical divider, mirroring Xcode's welcome
/// window:
///
/// - **Left**: a centered (H+V) stack — hammer icon, "Start Building
///   <folder>" single-line heading, and an optional source-branch row
///   (branch picker + Worktree checkbox). The branch row hides entirely
///   when the chosen folder is not a git repo or HEAD is detached.
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
    static let height: CGFloat = 300
    /// Right-column width. Left column takes the rest minus a 1pt divider.
    private static let recentColumnWidth: CGFloat = 240

    @Environment(SessionManager2.self) private var manager
    @State private var branches: [String] = []
    @State private var currentBranch: String? = nil
    @State private var isGitRepo: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            Divider()
            rightPanel
                .frame(width: Self.recentColumnWidth, alignment: .top)
                .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .testIdentifier("NewSession.Card")
        .onChange(of: folderPath) { _, _ in refreshGitInfo(resetOverride: true) }
        .task { refreshGitInfo(resetOverride: true) }
    }

    // MARK: - Left panel

    /// Centered (H+V) stack: hammer icon, single-line title, optional
    /// branch row. The branch row fades in / out so switching between a
    /// git folder and a plain folder doesn't snap the layout.
    @ViewBuilder
    private var leftPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 56)

            Text(headingText)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            if currentBranch != nil {
                HStack(spacing: 10) {
                    branchPicker
                    Toggle(isOn: $useWorktree) {
                        Text(String(localized: "Worktree"))
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .testIdentifier("NewSession.WorktreeToggle")
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: currentBranch)
    }

    /// "Start Building <folder>" on one line. Folder name is trimmed of
    /// trailing whitespace; when no folder is picked yet, fall back to
    /// the bare title.
    private var headingText: String {
        let base = String(localized: "Start Building")
        guard let folder = folderPath else { return base }
        let name = (folder as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? base : "\(base) \(name)"
    }

    @ViewBuilder
    private var branchPicker: some View {
        let displayBranch = sourceBranch ?? currentBranch ?? ""
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
    ///
    /// `resetOverride` forces `sourceBranch` back to the new repo's
    /// current branch — needed when the folder changes, otherwise the
    /// previous folder's branch selection would survive even if the new
    /// repo happens to have a branch by the same name.
    private func refreshGitInfo(resetOverride: Bool) {
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
            let head = GitUtils.currentBranch(at: path)
            currentBranch = head
            branches = Self.listBranches(at: path)
            if resetOverride || sourceBranch == nil || !branches.contains(sourceBranch ?? "") {
                sourceBranch = head
            }
            if head == nil {
                // Detached HEAD: branch row is hidden, so worktree must
                // not stay accidentally enabled.
                useWorktree = false
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
    .frame(width: 720, height: 460)
    .environment(SessionManager2())
}

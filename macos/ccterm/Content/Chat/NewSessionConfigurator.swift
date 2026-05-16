import AppKit
import SwiftUI

/// "Compose" card shown above the input bar on the New Session tab. Two
/// columns (no visible divider), mirroring Xcode's welcome window:
///
/// - **Left**: a centered (H+V) stack — hammer icon, "Start Building
///   <folder>" single-line heading, and a branch + Worktree row that
///   fades in / out (opacity-only, so the icon/title don't shift) when
///   the picked folder is or isn't a git repo with a named HEAD.
/// - **Right**: a sidebar-styled list of recent project folders backed
///   by `RecentProjectsStore` (UserDefaults). Selecting one writes back
///   through `folderPath`. Each row has a right-click menu (Reveal in
///   Finder / Remove from Recents).
///
/// State for the chosen folder / branch / worktree flag is owned by the
/// caller (RootView2) so the same values feed straight into the submit
/// path — this view holds only derived caches (git probe results).
struct NewSessionConfigurator: View {
    @Binding var folderPath: String?
    @Binding var useWorktree: Bool
    @Binding var sourceBranch: String?

    /// Fixed visual height; the parent assumes this when computing the
    /// compose-mode vertical centering padding.
    static let height: CGFloat = 300
    /// Right-column width. Left column takes the rest. Roughly 38% of
    /// the 544pt compose width — same proportion Xcode's welcome window
    /// uses for its recents pane.
    private static let recentColumnWidth: CGFloat = 200
    /// Outer card corner radius. Shared by the unified surface, the
    /// content clip, and the stroke overlay so the geometry stays
    /// consistent regardless of platform branch in `BarSurfaceModifier`.
    private static let cardCornerRadius: CGFloat = 12

    @Environment(RecentProjectsStore.self) private var recents
    @State private var branches: [String] = []
    @State private var currentBranch: String? = nil
    @State private var isGitRepo: Bool = false
    @State private var showBranchPicker: Bool = false

    var body: some View {
        // One unified card (single rounded rect with `barSurface` —
        // Liquid Glass on macOS 26+, thick material on older) split
        // visually into two halves by a darker fill + a 0.5pt vertical
        // separator on the right pane. Mirrors Xcode's welcome window:
        // same block, just cut in two.
        HStack(spacing: 0) {
            leftPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)

            rightPanel
                .frame(width: Self.recentColumnWidth)
                .frame(maxHeight: .infinity)
                .background(
                    // Recess overlay: a touch darker than the unified
                    // material beneath. `Color.black.opacity(...)` so
                    // the effect rides on top of whatever the parent
                    // surface resolves to (glass / material / solid).
                    Color.black.opacity(0.18)
                )
                .overlay(alignment: .leading) {
                    // Hairline dividing the left and right halves.
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 0.5)
                }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius))
        .barSurface(cornerRadius: Self.cardCornerRadius)
        .testIdentifier("NewSession.Card")
        .task(id: folderPath) { refreshGitInfo(resetOverride: true) }
    }

    // MARK: - Left panel

    /// Centered (H+V) stack: hammer icon, single-line title, branch row.
    /// The branch row fades via opacity (never structurally removed) so
    /// the icon + title stay in the same position regardless of the
    /// picked folder's git status.
    @ViewBuilder
    private var leftPanel: some View {
        let branchVisible = currentBranch != nil
        // One flat VStack — every child is horizontally centered in the
        // left half. An earlier version nested a `.leading` sub-stack
        // to align the branch row with the title's leading edge, but
        // that pushed the title off-center whenever the (possibly
        // invisible) branch row was wider than the title text. Keeping
        // everything centered matches Xcode's welcome window and stays
        // stable across folder-pick states.
        VStack(spacing: 14) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 56)

            Text(headingText)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 10) {
                branchPill
                Toggle(isOn: $useWorktree) {
                    Text(String(localized: "Worktree"))
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .testIdentifier("NewSession.WorktreeToggle")
            }
            .opacity(branchVisible ? 1 : 0)
            .allowsHitTesting(branchVisible)
            .animation(.smooth(duration: 0.25), value: branchVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Branch trigger: hover-capsule pill that opens the popover-based
    /// `BranchPickerView` (the same reusable component the legacy chat
    /// stack used). Confirming a branch in the popover writes
    /// `sourceBranch` and dismisses.
    @ViewBuilder
    private var branchPill: some View {
        let displayBranch = sourceBranch ?? currentBranch ?? ""
        Button {
            showBranchPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14, height: 14)
                Text(displayBranch)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(HoverCapsuleStyle())
        .popover(isPresented: $showBranchPicker, arrowEdge: .bottom) {
            BranchPickerView(
                branches: branches,
                currentBranch: currentBranch,
                onSelect: { selected in
                    sourceBranch = selected
                    showBranchPicker = false
                }
            )
        }
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

            if recents.entries.isEmpty {
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
            ForEach(recents.entries) { entry in
                recentRow(entry)
                    .tag(entry.path as String?)
                    .contextMenu {
                        Button(String(localized: "Reveal in Finder")) {
                            revealInFinder(entry.path)
                        }
                        Button(String(localized: "Remove from Recents")) {
                            removeFromRecents(entry.path)
                        }
                    }
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
    private func recentRow(_ entry: RecentProjectsStore.Entry) -> some View {
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

    // MARK: - Folder picker / actions

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder for the new session")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            recents.add(url.path)
            folderPath = url.path
        }
    }

    private func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func removeFromRecents(_ path: String) {
        recents.remove(path)
        if folderPath == path {
            folderPath = nil
        }
    }

    // MARK: - Git probing

    /// Cache `isGitRepo` / `currentBranch` / `branches` for the picked
    /// folder. Called on appear and whenever `folderPath` changes (via
    /// `.task(id:)`). If the picked path no longer exists on disk, the
    /// recents entry is silently removed.
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
        // Stale recents entry: folder no longer exists. Drop it and
        // clear the selection so the user gets the no-folder UI.
        if !FileManager.default.fileExists(atPath: path) {
            recents.remove(path)
            folderPath = nil
            isGitRepo = false
            branches = []
            currentBranch = nil
            useWorktree = false
            sourceBranch = nil
            return
        }
        let repo = GitUtils.isGitRepository(at: path)
        let head = repo ? GitUtils.currentBranch(at: path) : nil
        let list = repo ? Self.listBranches(at: path) : []
        isGitRepo = repo
        currentBranch = head
        branches = list
        if repo {
            if resetOverride || sourceBranch == nil || !list.contains(sourceBranch ?? "") {
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
    .environment(RecentProjectsStore())
}

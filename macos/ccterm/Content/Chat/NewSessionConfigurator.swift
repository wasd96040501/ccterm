import AppKit
import SwiftUI

/// "Compose" region shown above the input bar on the New Session tab.
/// Deliberately *not* a card: the surface uses `.ultraThinMaterial`
/// with no stroke and no shadow, so it reads as a softly-tinted segment
/// of the window rather than a floating panel set on top of it. This
/// inverts the chrome relationship with the input bar below — the bar
/// keeps its full `barSurface` (stroke + shadow) because it's an action
/// control, while the compose region above is "page", not "tool".
///
/// Two columns inside the same surface:
///
/// - **Left**: a left- and top-aligned hero stack — eyebrow row (icon +
///   "New Session"), title with the project name tinted, an abbreviated
///   path subtitle, a hairline divider, a branch + Worktree meta row
///   (opacity-faded so the layout above doesn't shift when the picked
///   folder isn't a git repo), and a small `⌘↩ to send` hint anchored
///   to the bottom edge. A soft radial tint glow in the top-left gives
///   the region its visual weight on the left half so the right pane
///   doesn't tip the balance, and echoes the accent color used by the
///   eyebrow icon and the project name.
/// - **Right**: a sidebar-styled list of recent project folders backed
///   by `RecentProjectsStore` (UserDefaults). Selecting one writes back
///   through `folderPath`. The right pane uses an almost-invisible (2.5%
///   black) recess and a 0.5pt hairline separator so it reads as part
///   of the same surface, not a second card glued on.
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
    static let height: CGFloat = 400
    /// Right-column width. Left column takes the rest. ~36.8% of the
    /// 680pt compose width — same proportion as the previous 200/544
    /// design, scaled up so the card grows without changing its
    /// L/R balance.
    private static let recentColumnWidth: CGFloat = 250
    /// Outer card corner radius. Shared by the unified surface, the
    /// content clip, and the stroke overlay so the geometry stays
    /// consistent regardless of platform branch in `BarSurfaceModifier`.
    /// Matches `InputBarView2.cornerRadius` so the compose card and the
    /// resting input bar read as one continuous chrome family.
    private static let cardCornerRadius: CGFloat = InputBarView2.cornerRadius

    @Environment(RecentProjectsStore.self) private var recents
    @State private var branches: [String] = []
    @State private var currentBranch: String? = nil
    @State private var isGitRepo: Bool = false
    @State private var showBranchPicker: Bool = false

    var body: some View {
        // No `barSurface` — we deliberately skip the stroke + shadow
        // chrome so this region doesn't look like a card glued on top
        // of the window. The only surface treatment is a single
        // `.ultraThinMaterial` background plus a soft tint glow.
        HStack(spacing: 0) {
            leftPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)

            rightPanel
                .frame(width: Self.recentColumnWidth)
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.025))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 0.5)
                }
        }
        .background(atmosphericGlow)
        .background(
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
        .task(id: folderPath) { refreshGitInfo(resetOverride: true) }
    }

    /// Radial tint glow anchored to the top-left, dissipating across
    /// the region. This is what gives the compose surface its visual
    /// weight on the left half so the right pane (recents) doesn't tip
    /// the balance. It also gives the accent color a second presence on
    /// the surface — the eyebrow icon and the project name in the
    /// title both pick up this hue, so the tint is never "orphaned" the
    /// way a single blue icon would be on an otherwise neutral panel.
    /// Slightly dimmer than a fully-chromed card would need, because
    /// without a stroke / shadow there's no chrome to compete with.
    private var atmosphericGlow: some View {
        RadialGradient(
            gradient: Gradient(colors: [
                Color.accentColor.opacity(0.14),
                Color.accentColor.opacity(0.0),
            ]),
            center: UnitPoint(x: 0.10, y: 0.18),
            startRadius: 0,
            endRadius: 360
        )
    }

    // MARK: - Left panel

    /// Left- and top-aligned hero stack with a bottom-anchored hint.
    /// The branch row uses opacity-only show/hide so the rest of the
    /// stack doesn't reflow when the picked folder switches between
    /// git / non-git repos.
    @ViewBuilder
    private var leftPanel: some View {
        let branchVisible = currentBranch != nil
        VStack(alignment: .leading, spacing: 0) {
            titleRow

            subtitleView
                .padding(.top, 6)

            metaRow
                .padding(.top, 20)
                .opacity(branchVisible ? 1 : 0)
                .allowsHitTesting(branchVisible)
                .animation(.default, value: branchVisible)

            Spacer(minLength: 0)

            hintRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Default cross-fade when the picked folder changes. SwiftUI's
        // default transition is opacity, which is exactly what we want
        // for the title's project segment + the subtitle's path text.
        .animation(.default, value: folderPath)
    }

    /// "Start Building <name>" with the project name in the accent
    /// color. Composed via HStack rather than `+` Text composition so
    /// the project segment can use `.foregroundStyle(.tint)` (which is
    /// not a Text-returning modifier). The name uses
    /// `.contentTransition(.opacity)` so swapping between non-nil
    /// project names cross-fades; appearance/disappearance is animated
    /// by the parent's `.animation(.default, value: folderPath)`.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(localized: "Start Building"))
                .foregroundStyle(.primary)
            if let name = pickedFolderName {
                Text(name)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
        }
        .font(.title.weight(.semibold))
    }

    /// Trimmed last path component of `folderPath`, or `nil` if no
    /// folder is picked / the name is empty after trimming.
    private var pickedFolderName: String? {
        guard let folder = folderPath else { return nil }
        let name = (folder as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Subtitle: abbreviated path when a folder is picked, otherwise a
    /// short prompt directing the user to the recents list on the
    /// right. Replaces the previous design's centered single-line
    /// heading with real, useful context. `.contentTransition(.opacity)`
    /// gives a cross-fade when the path changes; appearance flips are
    /// animated by the parent's `.animation(.default, value: folderPath)`.
    @ViewBuilder
    private var subtitleView: some View {
        if let path = folderPath {
            Text(abbreviatedPath(path))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
        } else {
            Text(String(localized: "Pick a project on the right to begin."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Concentric-capsule meta row: outer Capsule is a soft tinted
    /// background that wraps the worktree menu + branch picker pills.
    /// Both inner pills use `HoverCapsuleStyle` (radius derives from
    /// content height); the outer capsule adds 2pt of padding so it
    /// shares the inner pills' center but has a 2pt-larger radius,
    /// giving the "concentric, one ring out" look. The outer fill is
    /// `quaternaryLabel` — a builtin semantic gray subtle enough that
    /// the inner pills' hover state (labelColor at 8%) still reads as
    /// a distinct overlay rather than being washed out.
    private var metaRow: some View {
        HStack(spacing: 6) {
            worktreeMenu
            branchPill
        }
        .padding(2)
        .background(
            Capsule().fill(Color(nsColor: .quaternaryLabelColor))
        )
        .fixedSize()
    }

    /// Worktree picker: hover-capsule menu with two options. Driving
    /// `useWorktree` directly lets the rest of the submit pipeline stay
    /// unchanged.
    @ViewBuilder
    private var worktreeMenu: some View {
        Menu {
            Button {
                useWorktree = false
            } label: {
                Label {
                    Text(String(localized: "Local"))
                } icon: {
                    if !useWorktree {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button {
                useWorktree = true
            } label: {
                Label {
                    Text(String(localized: "New Worktree"))
                } icon: {
                    if useWorktree {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: useWorktree ? "folder.badge.plus" : "folder")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14, height: 14)
                Text(useWorktree ? String(localized: "New Worktree") : String(localized: "Local"))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(HoverCapsuleStyle())
        .fixedSize()
    }

    /// `⌘↩ to send` hint, anchored to the bottom-left of the left
    /// panel. Tertiary color, monospaced glyph for the shortcut so it
    /// reads as a key cap. The shortcut is verified in
    /// `InputBarView2.handleSend` (Cmd+Return submits regardless of
    /// the user's Enter-to-send mode).
    private var hintRow: some View {
        HStack(spacing: 4) {
            Text(verbatim: "⌘ ↩")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(String(localized: "to send"))
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
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

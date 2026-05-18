import AppKit
import SwiftUI

/// "Compose" region shown on the New Session tab. A wide three-segment
/// surface (existing app sidebar + this card's left column + right
/// column) that fills the centre of the detail pane:
///
/// - **Left column** — `RecentProjectsStore`-backed list of recent
///   project folders with a "Projects" section header and a `+` button
///   to add a new folder. Selecting a row writes back through
///   `folderPath`. Light material recess + 0.5pt trailing hairline so
///   it reads as a navigation strip belonging to the same card surface,
///   not a panel glued on top.
/// - **Right column** — main content stack: hero header (eyebrow icon,
///   "Start Building <project>" title with the project name tinted),
///   abbreviated path, branch + worktree meta pills, divider, a
///   "Recent Sessions" list for the picked folder, divider, and the
///   *embedded input bar* (passed in via `inputBar:` from `RootView2`,
///   so the bar's structural identity and pill style are owned by
///   `RootView2` — this view just decides where the bar lives).
///
/// State for the chosen folder / branch / worktree flag is owned by the
/// caller (`RootView2`) so the same values feed straight into the
/// submit path — this view holds only derived caches (git probe
/// results). The embedded input bar is a `@ViewBuilder` slot rather
/// than a constructed child here so the bar's session-aware wiring
/// (submit / stop / running state) stays at `RootView2`'s level.
struct NewSessionConfigurator<InputBar: View>: View {
    @Binding var folderPath: String?
    @Binding var useWorktree: Bool
    @Binding var sourceBranch: String?
    /// Invoked when the user clicks a row in the "Recent Sessions"
    /// section. `RootView2` flips `selectedSessionId` to this value,
    /// swapping the compose card out for the chosen session's history.
    var onResumeSession: ((String) -> Void)? = nil
    /// Embedded input bar. Provided by `RootView2` so the bar's
    /// per-session wiring (submit / interrupt / running state) and pill
    /// style live there — this view only owns the bar's *position*
    /// inside the card.
    @ViewBuilder var inputBar: () -> InputBar

    /// Fixed visual width; `RootView2` sets the card's frame to this
    /// (the centred ZStack lays it out at full width / height).
    static var width: CGFloat { 960 }
    /// Fixed visual height; tall enough that the right column can host
    /// hero + meta + recents list + input bar without crowding, while
    /// still leaving generous breathing room above and below in a
    /// typical detail pane.
    static var height: CGFloat { 620 }
    /// Left-column width. Hosts the recent-projects nav. ~29% of the
    /// 960pt card width — feels like a "sidebar inside the card", not
    /// a near-50/50 split.
    private static var projectsColumnWidth: CGFloat { 280 }
    /// Outer card corner radius. Shared by the unified surface, the
    /// content clip, and the stroke overlay so the geometry stays
    /// consistent regardless of platform branch in `BarSurfaceModifier`.
    /// Matches `InputBarView2.cornerRadius` so the compose card and the
    /// resting input bar read as one continuous chrome family.
    private static var cardCornerRadius: CGFloat { InputBarView2.cornerRadius }
    /// Hit-target for the "+" button in the Projects header.
    private static var plusButtonSize: CGFloat { 22 }
    /// Bottom-fade scrim so the last recent-projects row dissolves
    /// into the card's bottom edge instead of slamming into a hard
    /// line. The matching top scrim was dropped — the "Projects"
    /// section header already creates a clear visual boundary.
    private static var recentsBottomScrimHeight: CGFloat { 24 }

    @Environment(RecentProjectsStore.self) private var recents
    @Environment(SessionManager.self) private var manager
    @State private var branches: [String] = []
    @State private var currentBranch: String? = nil
    @State private var remoteMainBranch: String? = nil
    @State private var currentBranchStatus: String? = nil
    @State private var isGitRepo: Bool = false
    @State private var showBranchPicker: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            projectsColumn
                .frame(width: Self.projectsColumnWidth)
                .frame(maxHeight: .infinity)
                // Slate-blue recess — desaturated cool gray with just
                // enough blue to read as a navigation/structure zone.
                // Indigo at 6% leaned visibly lavender on the
                // `ultraThinMaterial` base in light mode; this hue
                // sits closer to gray on the wheel so the column
                // still reads as cool/recessive without becoming a
                // tinted patch. The fixed RGB intentionally avoids
                // `NSColor.systemIndigo` for the same reason — the
                // system curve over-saturates in light mode.
                .background(Color(red: 0.40, green: 0.47, blue: 0.60).opacity(0.05))
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 0.5)
                }

            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(atmosphericGlow)
        .background(
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
        .task(id: folderPath) { refreshGitInfo(resetOverride: true) }
    }

    /// Radial tint glow anchored to the top-left, dissipating across
    /// the region. Gives the card its visual weight on the left so the
    /// right column doesn't tip the balance, and echoes the accent
    /// color used by the eyebrow icon and the project name. Slightly
    /// dimmer than a fully-chromed card would need.
    private var atmosphericGlow: some View {
        RadialGradient(
            gradient: Gradient(colors: [
                Color.accentColor.opacity(0.10),
                Color.accentColor.opacity(0.0),
            ]),
            center: UnitPoint(x: 0.18, y: 0.10),
            startRadius: 0,
            endRadius: 420
        )
    }

    // MARK: - Left column (Projects)

    /// Vertical stack: section header (with `+` button) at the top,
    /// scrollable list of recents below. Empty state replaces the list
    /// when the store has no entries.
    @ViewBuilder
    private var projectsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            projectsHeader
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 8)

            if recents.entries.isEmpty {
                emptyRecents
            } else {
                ZStack {
                    recentsList
                    // Bottom-only fade so the last row dissolves into
                    // the card's bottom edge. The matching top scrim
                    // was dropped — the section header already
                    // creates a clear visual boundary at the top, so
                    // a fade band there just dimmed the first entry.
                    FadeScrim(.bottomToTop, height: Self.recentsBottomScrimHeight, style: .ultraThinMaterial)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Section label + `+` button. Uses an uppercase eyebrow style so
    /// the header reads as a section divider rather than another title.
    private var projectsHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(String(localized: "Projects"))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: presentFolderPicker) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.plusButtonSize, height: Self.plusButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlusHoverButtonStyle())
            .help(String(localized: "Choose Folder…"))
        }
    }

    @ViewBuilder
    private var emptyRecents: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No recent projects"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(String(localized: "Tap + above to add one"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var recentsList: some View {
        List(selection: folderPathSelection) {
            ForEach(recents.entries) { entry in
                recentRow(entry)
                    .tag(entry.path as String?)
                    .background(HideEnclosingScrollerWidth())
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
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(abbreviatedPath(entry.path))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Right column (Main content + embedded input bar)

    /// Top-aligned hero + body + bottom-anchored input bar. The middle
    /// "recent sessions" section absorbs the slack so the input bar
    /// sits at the same Y regardless of how many recents the user has.
    @ViewBuilder
    private var mainColumn: some View {
        let branchVisible = currentBranch != nil
        let recentSessions = recentSessionsForFolder
        VStack(alignment: .leading, spacing: 0) {
            titleRow
                .padding(.horizontal, 28)
                .padding(.top, 26)

            subtitleView
                .padding(.horizontal, 28)
                .padding(.top, 6)

            if branchVisible {
                metaRow
                    .padding(.leading, 28 - 6)
                    .padding(.top, 10)
            }

            Divider()
                .padding(.horizontal, 28)
                .padding(.top, 18)

            recentSessionsHeader
                .padding(.horizontal, 28)
                .padding(.top, 14)

            recentSessionsBody(recentSessions)
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Input bar zone: the embedded bar provided by
            // `RootView2`. The bar's own internal layout (pill,
            // attach, chrome row) is untouched — this view only
            // positions it. No divider above the bar; the pill's own
            // stroke is the visual edge.
            inputBar()
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Start Building <name>" with the project name in the accent
    /// color.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text(String(localized: "Start Building"))
                .foregroundStyle(.primary)
            if let name = pickedFolderName {
                Text(name)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
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
    /// short prompt directing the user to the projects list on the left.
    @ViewBuilder
    private var subtitleView: some View {
        if let path = folderPath {
            Text(abbreviatedPath(path))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(String(localized: "Pick a project on the left to begin."))
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

    /// Meta row: worktree picker + branch picker, side by side. Each
    /// inner pill carries its own hover background; the static stroke
    /// added here keeps them readable as buttons even before hover.
    private var metaRow: some View {
        HStack(spacing: 4) {
            worktreeMenu
            branchPill
        }
        .fixedSize()
    }

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
        .overlay(
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        )
        .fixedSize()
    }

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
        .overlay(
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        )
        .popover(isPresented: $showBranchPicker, arrowEdge: .bottom) {
            BranchPickerView(
                branches: branches,
                currentBranch: currentBranch,
                remoteMainBranch: remoteMainBranch,
                currentBranchStatus: currentBranchStatus,
                onSelect: { selected in
                    sourceBranch = selected
                    showBranchPicker = false
                }
            )
        }
    }

    // MARK: - Recent sessions section

    /// Maximum rows the Continue section shows. Picked so the section
    /// fits comfortably without scrolling; extra sessions are reachable
    /// via the sidebar.
    private static var resumeRowLimit: Int { 5 }

    /// Top N non-archived sessions whose `groupingPath` matches the
    /// picked folder, descending by `lastActiveAt`.
    private var recentSessionsForFolder: [SessionRecord] {
        guard let folder = folderPath else { return [] }
        return
            manager.records
            .lazy
            .filter { $0.status != .archived && $0.groupingPath == folder }
            .prefix(Self.resumeRowLimit)
            .map { $0 }
    }

    /// Section eyebrow for the recent-sessions list. Same uppercase
    /// label family used by the Projects header on the left so both
    /// columns share a visual rhythm.
    private var recentSessionsHeader: some View {
        Text(String(localized: "Recent Sessions"))
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func recentSessionsBody(_ records: [SessionRecord]) -> some View {
        if records.isEmpty {
            VStack(spacing: 0) {
                Text(
                    folderPath == nil
                        ? String(localized: "Pick a project to see its history.")
                        : String(localized: "No recent sessions for this project.")
                )
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } else {
            VStack(spacing: 0) {
                ForEach(records) { record in
                    resumeRow(record)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, -Self.resumeRowHPad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static var resumeRowHPad: CGFloat { 8 }

    @ViewBuilder
    private func resumeRow(_ record: SessionRecord) -> some View {
        let title = record.title.isEmpty ? String(localized: "Untitled") : record.title
        Button {
            onResumeSession?(record.sessionId)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(Self.compactRelative(from: record.lastActiveAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Self.resumeRowHPad)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ResumeRowButtonStyle())
    }

    /// Compact relative-time string. Caps everything ≥ 7 days at
    /// ">7d".
    static func compactRelative(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return ">7d"
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
    /// folder. Called on appear and whenever `folderPath` changes.
    /// `resetOverride` forces `sourceBranch` back to the new repo's
    /// current branch — needed when the folder changes.
    private func refreshGitInfo(resetOverride: Bool) {
        guard let path = folderPath else {
            isGitRepo = false
            branches = []
            currentBranch = nil
            remoteMainBranch = nil
            currentBranchStatus = nil
            useWorktree = false
            sourceBranch = nil
            return
        }
        if !FileManager.default.fileExists(atPath: path) {
            recents.remove(path)
            folderPath = nil
            isGitRepo = false
            branches = []
            currentBranch = nil
            remoteMainBranch = nil
            currentBranchStatus = nil
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
        remoteMainBranch = repo ? Self.remoteMainBranch(at: path) : nil
        currentBranchStatus = (repo && head != nil) ? Self.gitStatusSummary(at: path) : nil
        if repo {
            if resetOverride || sourceBranch == nil || !list.contains(sourceBranch ?? "") {
                sourceBranch = head
            }
            if head == nil {
                useWorktree = false
            } else {
                useWorktree = recents.useWorktree(for: path) ?? false
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

    private static func remoteMainBranch(at path: String) -> String? {
        let result = Worktree.runGit(
            ["symbolic-ref", "--short", "--quiet", "refs/remotes/origin/HEAD"],
            cwd: path,
            timeout: 5
        )
        guard result.exitCode == 0,
            let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
            !stdout.isEmpty
        else {
            return nil
        }
        return stdout
    }

    private static func gitStatusSummary(at path: String) -> String? {
        var parts: [String] = []
        let porcelain = Worktree.runGit(
            ["status", "--porcelain"],
            cwd: path,
            timeout: 5
        )
        if porcelain.exitCode == 0, let out = porcelain.stdout {
            var modified = 0
            var untracked = 0
            for raw in out.split(separator: "\n") {
                let line = String(raw)
                if line.hasPrefix("??") {
                    untracked += 1
                } else if !line.isEmpty {
                    modified += 1
                }
            }
            if modified == 0 && untracked == 0 {
                parts.append(String(localized: "Clean"))
            } else {
                var subs: [String] = []
                if modified > 0 { subs.append(String(localized: "\(modified) changed")) }
                if untracked > 0 { subs.append(String(localized: "\(untracked) untracked")) }
                parts.append(subs.joined(separator: ", "))
            }
        }

        let tracking = Worktree.runGit(
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
            cwd: path,
            timeout: 5
        )
        if tracking.exitCode == 0,
            let out = tracking.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            let cols = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if cols.count == 2, let behind = Int(cols[0]), let ahead = Int(cols[1]) {
                var arrows: [String] = []
                if ahead > 0 { arrows.append("↑\(ahead)") }
                if behind > 0 { arrows.append("↓\(behind)") }
                if !arrows.isEmpty {
                    parts.append(arrows.joined(separator: " "))
                }
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Hover/press background for the `+` button on the Projects header.
private struct PlusHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(
                        Color.primary.opacity(
                            configuration.isPressed ? 0.15 : (isHovered ? 0.08 : 0)
                        )
                    )
            )
            .onHover { isHovered = $0 }
    }
}

/// Hover/press background for a single recent-session row. Flat (no
/// border, no static fill) so the section reads as a list of links.
private struct ResumeRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return configuration.label
            .background(
                shape.fill(
                    Color(nsColor: .labelColor).opacity(
                        configuration.isPressed ? 0.10 : (isHovered ? 0.06 : 0)
                    )
                )
            )
            .onHover { isHovered = $0 }
    }
}

/// Invisible probe used as the `.background` of each recents row, used
/// to suppress the enclosing scroller width — see the original
/// docs above for the AppKit interop details.
private struct HideEnclosingScrollerWidth: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollerHidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollerHidingView)?.applySettings()
    }

    private final class ScrollerHidingView: NSView {
        private weak var trackedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            schedule()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        private func schedule() {
            DispatchQueue.main.async { [weak self] in
                self?.applySettings()
            }
        }

        fileprivate func applySettings() {
            guard let scrollView = enclosingScrollView else { return }
            if trackedScrollView !== scrollView {
                if let prev = trackedScrollView {
                    NotificationCenter.default.removeObserver(self, name: nil, object: prev)
                    if let prevDoc = prev.documentView {
                        NotificationCenter.default.removeObserver(self, name: nil, object: prevDoc)
                    }
                }
                trackedScrollView = scrollView
                scrollView.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(reapply),
                    name: NSView.frameDidChangeNotification,
                    object: scrollView
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(reapply),
                    name: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(reapply),
                    name: NSScrollView.didLiveScrollNotification,
                    object: scrollView
                )
                if let documentView = scrollView.documentView {
                    documentView.postsBoundsChangedNotifications = true
                    documentView.postsFrameChangedNotifications = true
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(reapply),
                        name: NSView.boundsDidChangeNotification,
                        object: documentView
                    )
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(reapply),
                        name: NSView.frameDidChangeNotification,
                        object: documentView
                    )
                }
            }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScroller?.scrollerStyle = .overlay
            scrollView.verticalScroller?.alphaValue = 0
            scrollView.verticalScroller?.isHidden = true
            scrollView.horizontalScroller?.scrollerStyle = .overlay
            scrollView.horizontalScroller?.alphaValue = 0
            scrollView.horizontalScroller?.isHidden = true
            scrollView.contentInsets = NSEdgeInsets()
            scrollView.scrollerInsets = NSEdgeInsets()
            scrollView.tile()
        }

        @objc private func reapply() {
            applySettings()
        }
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
            sourceBranch: $sourceBranch,
            inputBar: { Color.clear.frame(height: 64) }
        )
        .padding(40)
    }
    .frame(width: 1080, height: 760)
    .environment(RecentProjectsStore())
    .environment(SessionManager())
}

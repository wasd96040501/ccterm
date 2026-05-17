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
    /// Invoked when the user clicks the "Continue last session" card.
    /// `RootView2` flips `selectedSessionId` to this value, swapping the
    /// compose card out for the chosen session's history.
    var onResumeSession: ((String) -> Void)? = nil

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
    /// Hit-target for the "+" button in the recents header. Sized so the
    /// inset that lands its centre on the corner-arc centre
    /// (`cardCornerRadius - plusButtonSize/2`) stays a clean integer (7).
    private static let plusButtonSize: CGFloat = 18

    @Environment(RecentProjectsStore.self) private var recents
    @Environment(SessionManager2.self) private var manager
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

            // `padding(.leading, -6)` pulls the metaRow out by exactly
            // the HoverCapsule's internal hpad, so the visible content
            // (folder icon) aligns with the title's text leading edge
            // rather than the invisible capsule edge.
            metaRow
                .padding(.leading, -6)
                .padding(.top, 6)
                .opacity(branchVisible ? 1 : 0)
                .allowsHitTesting(branchVisible)

            let recentSessions = recentSessionsForFolder
            if !recentSessions.isEmpty {
                resumeList(recentSessions)
                    .padding(.top, 18)
            }

            Spacer(minLength: 0)

            hintRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Maximum rows the Continue section shows. Picked so the section
    /// fits comfortably in the fixed `Self.height` left column without
    /// pushing `hintRow` out of view. No scroll — extra sessions are
    /// reachable via the sidebar.
    private static let resumeRowLimit = 5

    /// Top N non-archived sessions whose `groupingPath` matches the
    /// picked folder, descending by `lastActiveAt`. `manager.records`
    /// is `@Observable` and already sorted that way, so the prefix is
    /// correct without an explicit sort.
    private var recentSessionsForFolder: [SessionRecord] {
        guard let folder = folderPath else { return [] }
        return
            manager.records
            .lazy
            .filter { $0.status != .archived && $0.groupingPath == folder }
            .prefix(Self.resumeRowLimit)
            .map { $0 }
    }

    /// Horizontal breathing room inside each resume row. Negative-padded
    /// on the list container by the same amount so the row content
    /// (title text) lines up with the title above, while the hover bg
    /// extends outward into the leftPanel's outer padding to give the
    /// row a comfortable hit-target — same alignment trick used by
    /// `metaRow` for the worktree capsule.
    private static let resumeRowHPad: CGFloat = 8

    /// Flat list of recent sessions: no header, no surrounding chrome.
    /// Rows expand to fill the left panel's width; content aligns to
    /// the title above, hover bg extends `resumeRowHPad` past on each
    /// side via the negative padding below.
    @ViewBuilder
    private func resumeList(_ records: [SessionRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(records) { record in
                resumeRow(record)
            }
        }
        .padding(.horizontal, -Self.resumeRowHPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Single resume row: title flush-left, compact relative time
    /// flush-right. Zero horizontal padding so the title's leading
    /// edge sits at the same x as the title above; vertical padding
    /// gives a comfortable click target and a subtle hover-bg breath.
    @ViewBuilder
    private func resumeRow(_ record: SessionRecord) -> some View {
        let title = record.title.isEmpty ? String(localized: "Untitled") : record.title
        Button {
            onResumeSession?(record.sessionId)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(Self.compactRelative(from: record.lastActiveAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Self.resumeRowHPad)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ResumeRowButtonStyle())
    }

    /// Compact relative-time string. Caps everything ≥ 7 days at
    /// ">7d" — beyond that the exact age stops being useful and the
    /// row should read as "old, look elsewhere". Localised through the
    /// `now` literal only; the suffix-letter forms (m / h / d) are
    /// universal enough to leave as ASCII.
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

    /// "Start Building <name>" with the project name in the accent
    /// color. Composed via HStack rather than `+` Text composition so
    /// the project segment can use `.foregroundStyle(.tint)` (which is
    /// not a Text-returning modifier).
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(localized: "Start Building"))
                .foregroundStyle(.primary)
            if let name = pickedFolderName {
                Text(name)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
    /// short prompt directing the user to the recents list on the right.
    /// Replaces the previous design's centered single-line heading with
    /// real, useful context.
    @ViewBuilder
    private var subtitleView: some View {
        if let path = folderPath {
            Text(abbreviatedPath(path))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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

    /// Meta row: worktree picker + branch picker, side by side. Each
    /// inner pill carries its own hover background via
    /// `HoverCapsuleStyle`; no shared container chrome.
    private var metaRow: some View {
        HStack(spacing: 2) {
            worktreeMenu
            branchPill
        }
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
        // Geometry: the top-right corner-arc centre sits at
        // (cornerRadius, cornerRadius) inset from the card's top-right
        // edge. Align the button's *centre* on that arc centre — its
        // top-left then sits at (cornerRadius - plusButtonSize/2). Then
        // nudge 2pt further inside (down + left) so the glyph reads as
        // tucked into the corner rather than tangent to the arc.
        let plusInset = Self.cardCornerRadius - Self.plusButtonSize / 2 + 2
        VStack(alignment: .trailing, spacing: 0) {
            Button(action: presentFolderPicker) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.plusButtonSize, height: Self.plusButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Choose Folder…"))
            .padding(.top, plusInset)
            .padding(.trailing, plusInset)

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
        // state RootView2 reads at submit time. `.scrollIndicators` is
        // ignored by macOS `List`, and SwiftUI doesn't add `.background`
        // views as descendants of the List's `NSScrollView` —  so we
        // stash an `enclosingScrollView`-based probe on EACH row's
        // background. The probe's `NSView` lands inside a
        // `NSTableCellView`, which IS inside the List's
        // `NSScrollView`, so `enclosingScrollView` resolves; redundant
        // probes are idempotent. Beats inlining a 0-height probe row
        // because sidebar `List` enforces a ~28pt min row height that
        // would open a gap above the first real entry.
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

/// Hover/press background for a single Continue-section row. Flat
/// (no border, no static fill) so the section reads as a list of
/// links rather than a stack of cards. Same opacity ladder as
/// `HoverCapsuleStyle` — 8% pressed, 6% hovered — to keep all
/// hover affordances in this view family consistent.
private struct ResumeRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return configuration.label
            .background(
                shape.fill(
                    Color(nsColor: .labelColor).opacity(
                        configuration.isPressed ? 0.08 : (isHovered ? 0.06 : 0)
                    )
                )
            )
            .onHover { isHovered = $0 }
    }
}

/// Invisible probe used as the `.background` of each recents row. Once
/// SwiftUI installs the probe's `NSView` into the host `NSTableCellView`,
/// `enclosingScrollView` returns the List's `NSScrollView`; we then
/// force scrollers off AND switch to overlay style. SwiftUI re-applies
/// `List`'s own scroller settings on every layout pass (e.g. when a
/// row's selection state changes), undoing a one-shot disable — so we
/// also observe the scroll view's `frameDidChange` / live-scroll
/// notifications and re-apply on each, plus call `tile()` to force the
/// scroll view to immediately re-lay out without a gutter. The combo
/// of `scrollerStyle = .overlay` + `hasVerticalScroller = false` is
/// the only one I've seen actually reclaim the gutter under macOS's
/// "Always show scroll bars" preference.
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
                // The document view is the `NSTableView`. Its bounds
                // change when row selection updates, content grows /
                // shrinks, or sidebar redraws — each of those is the
                // moment AppKit re-tiles the scroll view and any
                // previously-disabled scroller comes back. Catch the
                // bounds notification and reapply.
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
            sourceBranch: $sourceBranch
        )
        .frame(width: 544)
        .padding(40)
    }
    .frame(width: 720, height: 460)
    .environment(RecentProjectsStore())
    .environment(SessionManager2())
}

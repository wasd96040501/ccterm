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

    /// Card width band. The card grows with the detail pane up to
    /// `maxWidth` and falls back to `minWidth` when the window is at
    /// its lower limit — never wider, never narrower. `minWidth` is
    /// chosen so the two-column layout (Projects + main) stays
    /// readable at the smallest window size: Projects column is fixed
    /// at 280pt, leaving ~360pt for the main column, enough for the
    /// hero, recents list and the embedded input bar.
    /// `RootView2.minWidth` (880) = sidebar min (220) + this `minWidth`
    /// + a small buffer, guaranteeing the card never clips when the
    /// user shrinks the window.
    static var minWidth: CGFloat { 640 }
    static var idealWidth: CGFloat { 960 }
    static var maxWidth: CGFloat { 960 }
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
    /// Branch list + remote main + current-branch status are only ever shown
    /// inside `BranchPickerView`. The probe is preloaded asynchronously when
    /// the picked folder is a git repo (see `GitProbe.loadHeavy`) so the popover
    /// already has data the moment the user clicks the branch pill — the
    /// subprocess cost is paid in the background while the user is reading
    /// the rest of the card.
    @State private var probe: GitProbe
    @State private var showBranchPicker: Bool = false

    init(
        folderPath: Binding<String?>,
        useWorktree: Binding<Bool>,
        sourceBranch: Binding<String?>,
        onResumeSession: ((String) -> Void)? = nil,
        @ViewBuilder inputBar: @escaping () -> InputBar
    ) {
        self._folderPath = folderPath
        self._useWorktree = useWorktree
        self._sourceBranch = sourceBranch
        self.onResumeSession = onResumeSession
        self.inputBar = inputBar
        // Seed the cheap probe synchronously so the branch pill renders on the
        // very first frame. Without this, `.task(id: folderPath)` only fires
        // after the view appears — `probe.currentBranch` is nil for one frame,
        // the conditional `metaRow` pops in, and everything below it (divider,
        // recents, input bar) gets shoved down a row. The heavy probe
        // (branches list / status / remote main) still runs async in `.task`.
        self._probe = State(initialValue: GitProbe(seedFolderPath: folderPath.wrappedValue))
    }

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
        .frame(
            minWidth: Self.minWidth,
            idealWidth: Self.idealWidth,
            maxWidth: Self.maxWidth,
            minHeight: Self.height,
            idealHeight: Self.height,
            maxHeight: Self.height
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
        // Soft drop shadow so the card reads as a floating panel on the
        // vibrancy backdrop instead of a flat slab sharing its plane.
        // Tuned to be felt, not seen — small enough not to add visual
        // weight to the otherwise restrained surface.
        .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 10)
        .task(id: folderPath) {
            // Two-stage probe, both keyed off `folderPath`:
            //   1) Cheap, synchronous — `GitProbe.refresh` reads
            //      `.git/HEAD` and the `.git` existence flag, resolving
            //      `probe.currentBranch` / `probe.isGitRepo` before
            //      the first frame so the branch pill renders its
            //      label immediately.
            //   2) Heavy, async — `GitProbe.loadHeavy` fans out three
            //      git subprocesses on a detached background task so
            //      the main thread keeps painting. Folder switches
            //      cancel this `.task` via the `id:` parameter, and the
            //      probe's post-`await` guard drops any late-arriving
            //      result whose folder no longer matches.
            //
            // The branch picker no longer triggers a load on open —
            // by the time the user clicks the pill, `probe.branches`
            // is already populated (or actively loading; the picker
            // shows a blank list slot and animates rows in when data
            // lands).
            probe.refresh(folderPath: folderPath)
            applyProbeBindings(resetOverride: true)
            await probe.loadHeavy(folderPath: folderPath)
            // Validate any saved branch override against the real list
            // now that we have it. A stale ref (the branch was deleted
            // on disk) falls back to HEAD.
            if let sb = sourceBranch, !probe.branches.isEmpty,
                !probe.branches.contains(sb)
            {
                sourceBranch = probe.currentBranch
            }
        }
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
        ScrollViewReader { proxy in
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
            // Prepended entries (RecentProjectsStore.add / markLaunched)
            // leave the sidebar List's NSScrollView with a stale top
            // contentInset that clips row 0 by a few pixels until the
            // user scrolls. A no-animation scrollTo on the new first
            // row drives HideEnclosingScrollerWidth's willStartLiveScroll
            // reapply, zeroing the inset immediately.
            .onChange(of: recents.entries.first?.id) { _, newId in
                guard let newId else { return }
                withAnimation(.none) {
                    proxy.scrollTo(newId, anchor: .top)
                }
            }
        }
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

    /// Reserved bottom space inside `mainColumn` so the recents list
    /// stops above where the input bar lives. Sized for the bar at rest
    /// (pill 32 + chrome spacing 10 + chrome row 22 + top/bottom
    /// paddings 14+18). The bar is rendered as a z-axis overlay rather
    /// than a VStack sibling so that completion popups expand upward
    /// over the recents list instead of squeezing the pill's text row.
    /// Computed (not stored) because Swift bans `static let` on generic
    /// types.
    private static var inputBarReservedHeight: CGFloat { 96 }

    /// Top-aligned hero + body + bottom-anchored input bar. The middle
    /// "recent sessions" section absorbs the slack so the input bar
    /// sits at the same Y regardless of how many recents the user has.
    /// The bar itself is overlaid on the z-axis (see
    /// `inputBarReservedHeight`) so an open completion popup can grow
    /// upward over the recents list rather than compress the pill.
    @ViewBuilder
    private var mainColumn: some View {
        let branchVisible = probe.currentBranch != nil
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
                .padding(.bottom, Self.inputBarReservedHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            // Bar lives on the z-axis, not as a VStack sibling — its
            // maximum height equals the whole card, so an open
            // completion popup grows upward freely (clipped only by
            // the card's outer `clipShape` at the top edge) instead
            // of being squeezed by the recents list above.
            inputBar()
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
        }
    }

    /// "Start Building <name>" with the project name in the accent
    /// color.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                // Optical-center alignment: a 16pt SF Symbol baseline-aligned
                // to 22pt (.title) CJK text sits ~2pt below the text's visual
                // center because the em-box midpoints diverge with the size
                // delta. Shift the symbol up by 2pt so the centers line up.
                .alignmentGuide(.firstTextBaseline) { d in
                    d[.firstTextBaseline] + 2
                }
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
            // Inline Picker so AppKit drives the menu-item state — the
            // unselected row keeps the leading checkmark column reserved,
            // keeping both labels vertically aligned. A pair of buttons
            // with a conditionally-rendered checkmark icon collapses the
            // icon column when absent and shifts the unselected label left.
            Picker(selection: $useWorktree) {
                Text(String(localized: "Local")).tag(false)
                Text(String(localized: "New Worktree")).tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
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
        let displayBranch = sourceBranch ?? probe.currentBranch ?? ""
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
                branches: probe.branches,
                currentBranch: probe.currentBranch,
                remoteMainBranch: probe.remoteMainBranch,
                currentBranchStatus: probe.currentBranchStatus,
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

    // MARK: - Git probe ↔ binding glue

    /// Maps `probe`'s post-`refresh` state into the configurator's
    /// `sourceBranch` / `useWorktree` bindings, and handles the
    /// recents-side cleanup when the picked folder no longer exists.
    /// Called right after `probe.refresh(folderPath:)` from the card's
    /// `.task`, before the heavy load awaits.
    ///
    /// `resetOverride` forces `sourceBranch` back to the new repo's
    /// current branch — passed `true` on folder change so a leftover
    /// override from the previous folder doesn't survive the switch.
    private func applyProbeBindings(resetOverride: Bool) {
        guard let path = folderPath else {
            useWorktree = false
            sourceBranch = nil
            return
        }
        if !FileManager.default.fileExists(atPath: path) {
            recents.remove(path)
            folderPath = nil
            useWorktree = false
            sourceBranch = nil
            return
        }
        if probe.isGitRepo {
            // Cheap path: we can't validate `sourceBranch` against the
            // real branch list here (that's the heavy path). The card's
            // `.task` reconciles a stale override against the loaded
            // list after `loadHeavy` returns. For everything else, fall
            // back to HEAD.
            if resetOverride || sourceBranch == nil {
                sourceBranch = probe.currentBranch
            }
            if probe.currentBranch == nil {
                useWorktree = false
            } else {
                useWorktree = recents.useWorktree(for: path) ?? false
            }
        } else {
            useWorktree = false
            sourceBranch = nil
        }
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

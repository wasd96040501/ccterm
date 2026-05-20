import SwiftUI

/// Read-only browser for soft-deleted sessions, opened from the sidebar's
/// "Archive" item. The list is sourced from
/// `SessionManager.archivedRecords` — a lazily-populated observable
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
/// ├── Header (title only — leading-aligned with row text column)
/// └── ScrollView
///     └── LazyVStack(spacing: 0)
///         ├── if filteredRecords.isEmpty → EmptyState / NoMatchState
///         └── else ForEach(records) {
///                 ArchiveRow
///                 + Divider (between rows, never trailing)
///             }
/// ```
///
/// Window toolbar (pinned to the trailing edge via `ToolbarSpacer` on
/// macOS 26+, naturally trailing on older releases):
/// - `.searchable` for matching title / worktree branch. Backed by a
///   `Task.sleep(150ms)` debounce so a 10k-row dataset doesn't lag per
///   keystroke — the raw field text is read every keypress but the
///   filter only re-runs after the user pauses.
/// - A folder-filter button that opens `FolderFilterPickerView` in a
///   popover. The folder set is identity-derived from `originPath` (so
///   worktree sessions group with their parent repo) and cached in
///   `@State` — re-derived only when `manager.archivedRecords` changes,
///   not on every keystroke / body invalidation.
struct ArchiveView: View {
    @Environment(SessionManager.self) private var manager

    /// Caller-supplied unarchive sink so selection can hop back to the
    /// restored session in `RootView2`. Receives the restored
    /// `sessionId`; nil for the empty-state preview path.
    let onUnarchive: ((String) -> Void)?

    /// What the user is currently typing — fed by `.searchable`, read
    /// every keystroke. Distinct from `searchQuery` (the debounced
    /// value that actually drives filtering) so a fast typer doesn't
    /// trigger N filter passes over 10k rows.
    @State private var searchQueryRaw: String = ""
    /// Debounced search query — committed `searchDebounceMillis` after
    /// the last keystroke. `filteredRecords` reads this, not the raw
    /// field.
    @State private var searchQuery: String = ""
    /// `nil` means "All Folders"; otherwise the canonical
    /// `record.originPath` to match against.
    @State private var selectedFolderPath: String? = nil
    @State private var isFilterPopoverPresented: Bool = false
    /// Cached folder picker options — recomputed only when the archived
    /// record set changes (see `.onChange(of: archivedRecordsFingerprint)`).
    /// Computing it inline on every body call would re-group all rows
    /// on every keystroke; with the cache the keystroke path only pays
    /// for the filter pass.
    @State private var folderOptions: [FolderFilterPickerView.Folder] = []

    /// Flips to `true` once the first async fetch has landed. Until
    /// then the body renders an empty slot so the empty-state copy
    /// doesn't flash before the records arrive.
    @State private var isLoaded: Bool = false
    /// Drives the header spinner. Decoupled from `isLoaded` so a fast
    /// load skips the spinner entirely (anti-flicker debounce) and a
    /// slow load keeps it visible for at least `progressMinVisibleMillis`.
    @State private var showProgress: Bool = false
    /// Wall-clock timestamp recorded when the spinner first appears.
    /// Used to enforce the min-visible window so the spinner doesn't
    /// blink in and out for borderline-fast loads.
    @State private var progressShownAt: Date? = nil

    init(onUnarchive: ((String) -> Void)? = nil) {
        self.onUnarchive = onUnarchive
    }

    /// 150ms is the standard "user paused typing" threshold — short
    /// enough that the list reacts as fast as the eye registers a
    /// pause, long enough to skip mid-word filter passes.
    private static let searchDebounceMillis: UInt64 = 150

    /// Loading shorter than this never shows the spinner. Picks up the
    /// pathological "5k archived rows on a cold CoreData cache" path
    /// without paying for it on the common "a dozen rows" case.
    private static let progressShowDelayMillis: UInt64 = 250
    /// Once visible, the spinner stays up at least this long so a load
    /// that finishes 30ms after the spinner appears doesn't look like
    /// a render glitch.
    private static let progressMinVisibleMillis: UInt64 = 500
    /// Spinner fade in/out.
    private static let progressFadeDuration: Double = 0.18
    /// List fade-in when records first land.
    private static let contentFadeDuration: Double = 0.25

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                bodyContent
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
        .searchable(
            text: $searchQueryRaw,
            placement: .toolbar,
            prompt: Text("Search archived sessions")
        )
        .toolbar {
            // ToolbarSpacer is macOS 26+; on older releases the default
            // layout already trails our items to the right edge of the
            // detail-pane toolbar.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem(placement: .automatic) {
                filterButton
            }
        }
        .task { await loadArchivedAsync() }
        .task(id: searchQueryRaw) {
            // `.task(id:)` cancels the previous body when the raw text
            // changes, so the debounce is "fire only when no keystroke
            // arrives within the window." Cancellation throws out of
            // `Task.sleep`, which is exactly the behavior we want.
            do {
                try await Task.sleep(nanoseconds: Self.searchDebounceMillis * 1_000_000)
                searchQuery = searchQueryRaw
            } catch {}
        }
        .onChange(of: archivedRecordsFingerprint, initial: true) { _, _ in
            folderOptions = computeFolderOptions()
            // Drop a stale folder filter if the selected folder no
            // longer has any archived rows (user unarchived every row
            // under it from elsewhere).
            if let selected = selectedFolderPath,
                !folderOptions.contains(where: { $0.path == selected })
            {
                selectedFolderPath = nil
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if !isLoaded {
            // Placeholder while the first fetch is in flight. Keeps the
            // empty-state copy from flashing for one frame before the
            // records land.
            Color.clear
                .frame(height: 1)
        } else if manager.archivedRecords.isEmpty {
            ArchiveEmptyState()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .transition(.opacity)
        } else {
            let records = filteredRecords
            if records.isEmpty {
                ArchiveNoMatchState()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .transition(.opacity)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        ArchiveRow(
                            record: record,
                            onUnarchive: { unarchive(record) }
                        )
                        if index < records.count - 1 {
                            Divider()
                                .padding(.leading, Self.rowHorizontalPadding)
                        }
                    }
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
    }

    /// Header sits at the same leading inset as the row text column —
    /// matches `ArchiveRow`'s `rowHorizontalPadding` so the "Archive"
    /// title and the first row's title share a vertical line. Spinner
    /// sits flush right of the title under `.center` alignment so the
    /// 22pt cap height and the spinner glyph share a visual midline.
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Archive")
                .font(.system(size: 22, weight: .semibold))
            if showProgress {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
                    .frame(width: 16, height: 16)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: Self.progressFadeDuration), value: showProgress)
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.top, 40)
        .padding(.bottom, 16)
    }

    /// First-render async load. Sequence:
    ///
    /// 1. Schedule a deferred spinner show — only fires if the load is
    ///    still running after `progressShowDelayMillis`. Keeps the
    ///    spinner off-screen for the common "small archive, instant
    ///    fetch" case.
    /// 2. `Task.yield()` so SwiftUI lays out the header / chrome before
    ///    we hit storage.
    /// 3. `refreshArchivedRecordsAsync()` — CoreData repo fetches on a
    ///    background context; in-memory test repo falls back to a sync
    ///    read after a yield.
    /// 4. Cancel the deferred spinner task.
    /// 5. If the spinner did appear, enforce `progressMinVisibleMillis`
    ///    before hiding it — avoids the "flicker on, blink off" look
    ///    when the load lands a few ms after the spinner shows up.
    /// 6. Fade the spinner out and flip `isLoaded` so the records
    ///    crossfade in via `.transition(.opacity)`.
    ///
    /// Re-entry (view re-appears with `isLoaded` already true) skips
    /// the loading choreography and just does a cheap synchronous
    /// refresh so any out-of-band archive/unarchive lands in the list.
    @MainActor
    private func loadArchivedAsync() async {
        guard !isLoaded else {
            manager.refreshArchivedRecords()
            return
        }

        let progressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.progressShowDelayMillis * 1_000_000)
            guard !Task.isCancelled else { return }
            progressShownAt = Date()
            withAnimation(.easeInOut(duration: Self.progressFadeDuration)) {
                showProgress = true
            }
        }

        // Yield so the header / placeholder body get a frame before we
        // start the CoreData fetch. Without this the first paint
        // contains the records already and the fade-in is invisible.
        await Task.yield()

        await manager.refreshArchivedRecordsAsync()

        progressTask.cancel()

        if showProgress, let shownAt = progressShownAt {
            let elapsedMs = UInt64(max(0, Date().timeIntervalSince(shownAt) * 1000))
            if elapsedMs < Self.progressMinVisibleMillis {
                let remainingMs = Self.progressMinVisibleMillis - elapsedMs
                try? await Task.sleep(nanoseconds: remainingMs * 1_000_000)
            }
        }

        withAnimation(.easeOut(duration: Self.contentFadeDuration)) {
            showProgress = false
            isLoaded = true
        }
        progressShownAt = nil
    }

    private var filterButton: some View {
        Button {
            isFilterPopoverPresented.toggle()
        } label: {
            Image(
                systemName: selectedFolderPath == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .help(Text("Filter by folder"))
        .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .top) {
            FolderFilterPickerView(
                folders: folderOptions,
                selectedPath: selectedFolderPath,
                onSelect: { path in
                    selectedFolderPath = path
                    isFilterPopoverPresented = false
                }
            )
        }
    }

    /// Cheap fingerprint over `archivedRecords` so the `.onChange`
    /// trigger fires when the record set actually changes without
    /// allocating a 10k-element snapshot per body invalidation. Count
    /// + first/last sessionId catches every realistic mutation
    /// (archive, unarchive, refresh).
    private var archivedRecordsFingerprint: String {
        let records = manager.archivedRecords
        let first = records.first?.sessionId ?? ""
        let last = records.last?.sessionId ?? ""
        return "\(records.count)|\(first)|\(last)"
    }

    /// Distinct folder options drawn from the full archived list,
    /// keyed on `originPath` — worktree sessions group with their
    /// parent repo rather than appearing as a separate per-worktree
    /// row. Records without `originPath` aren't filterable and are
    /// silently dropped. Sorted alphabetically for predictable
    /// scanning.
    private func computeFolderOptions() -> [FolderFilterPickerView.Folder] {
        let buckets = Dictionary(grouping: manager.archivedRecords) { $0.originPath }
        return buckets.compactMap { path, _ -> FolderFilterPickerView.Folder? in
            guard let path, !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return FolderFilterPickerView.Folder(path: path, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Records after applying the in-memory folder and text filters.
    /// Folder filter matches `originPath`; text filter matches the
    /// title or `worktreeBranch` (case-insensitive substring on both).
    private var filteredRecords: [SessionRecord] {
        var records = manager.archivedRecords
        if let path = selectedFolderPath {
            records = records.filter { $0.originPath == path }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            records = records.filter { record in
                if record.title.localizedCaseInsensitiveContains(q) { return true }
                if let branch = record.worktreeBranch, branch.localizedCaseInsensitiveContains(q) {
                    return true
                }
                return false
            }
        }
        return records
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

/// One archived session. Two-line layout: title + (hover-only) unarchive
/// button on top, metadata strip + short relative time on the bottom.
/// Hover paints a soft background and reveals the unarchive button —
/// idle state is content-only so the list reads as a clean column.
///
/// Internal access so the snapshot test can compose the row in
/// isolation; see `ArchiveViewSnapshotTests`.
struct ArchiveRow: View {
    let record: SessionRecord
    let onUnarchive: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            topRow
            bottomRow
        }
        .padding(.horizontal, ArchiveView.rowHorizontalPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.04 : 0))
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// Title text on the left, unarchive button on the right. The
    /// button stays in the layout (transparent when idle) so revealing
    /// it on hover doesn't reflow the row.
    ///
    /// `padding(.trailing, -capsuleHorizontalPadding)` shifts the button
    /// rightward by exactly the capsule's internal padding so the
    /// "Unarchive" text edge — not the capsule edge — sits flush with
    /// the time text's right edge in the row below. The 6pt overflow
    /// falls inside the row's 12pt horizontal padding, so nothing
    /// clips.
    private var topRow: some View {
        HStack(spacing: 14) {
            titleText
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            unarchiveButton
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .padding(.trailing, -Self.capsuleHorizontalPadding)
        }
    }

    /// Mirrors `HoverCapsuleStyle.HoverCapsuleModifier`'s
    /// `.padding(.horizontal, 6)`. Pinned here as a constant so the
    /// trailing-edge alignment math is explicit; if the capsule style
    /// changes its padding, this value must follow.
    private static let capsuleHorizontalPadding: CGFloat = 6

    /// Metadata (folder + optional branch) on the left, short
    /// relative-time on the right. Time stays put as the row's
    /// permanent right-side anchor regardless of hover state.
    private var bottomRow: some View {
        HStack(spacing: 14) {
            metadataStrip
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(shortRelative)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
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

    /// Folder + (optional) worktree branch. Always renders the folder
    /// slot with the `folder` SF Symbol — the branch slot is what
    /// distinguishes a worktree row, rendered with `arrow.triangle.branch`
    /// only when `isWorktree` and a branch name is on hand.
    private var metadataStrip: some View {
        HStack(spacing: 6) {
            if let folder = folderLabel {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if record.isWorktree, let branch = record.worktreeBranch, !branch.isEmpty {
                if folderLabel != nil {
                    Text(verbatim: "·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(branch)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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

    /// Short relative-time string for the row's bottom-right slot.
    /// Format ladder is intentionally tight ("now" / "5min" /
    /// "3h" / "2d" / ">7d") so the time slot stays under 5–6
    /// characters and doesn't push the metadata strip into truncation.
    private var shortRelative: String {
        let date = record.archivedAt ?? record.lastActiveAt
        return Self.shortRelativeString(from: date)
    }

    /// Format ladder, exposed so snapshot / logic tests can pin the
    /// boundaries:
    ///   - < 60s  → "now"
    ///   - < 60m  → "Nmin"
    ///   - < 24h  → "Nh"
    ///   - ≤ 7d   → "Nd"
    ///   - > 7d   → ">7d"
    /// Future dates collapse to "now" — defensive against clock skew
    /// rather than a real case.
    static func shortRelativeString(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return String(localized: "now") }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)min" }
        let hours = Int(interval / 3600)
        if hours < 24 { return "\(hours)h" }
        let days = Int(interval / 86_400)
        if days <= 7 { return "\(days)d" }
        return ">7d"
    }
}

// MARK: - Empty / No-match state

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

/// Centered message when the archive list is non-empty but the active
/// search / folder filter excludes every row. Distinct from
/// `ArchiveEmptyState` so the user knows the data is there — just hidden
/// by the current query.
private struct ArchiveNoMatchState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No matching sessions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Try clearing the search or folder filter.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }
}

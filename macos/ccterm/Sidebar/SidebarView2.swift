import SwiftUI

/// Sidebar: a fixed top group of utility items (New Session, demos) plus
/// folder-grouped history below. Sourced directly from `SessionManager.records`,
/// grouped by `groupingFolderName`, sorted by `lastActiveAt` descending.
///
/// Component tree (intentionally flat — no `Section` wrappers, no
/// `DisclosureGroup`, so all rows share a single leading column and
/// align icon-to-icon / text-to-text):
///
/// ```
/// List(selection)
/// ├── SidebarItemRow × N      (fixed top items, icon + text)
/// └── ForEach(folders)
///     ├── SidebarFolderHeader (folder icon + dim text + chevron)
///     └── if expanded { ForEach(records) SidebarHistoryRow }
/// ```
///
/// Three row types — `SidebarItemRow`, `SidebarFolderHeader`,
/// `SidebarHistoryRow` — all share the same `SidebarIcon` slot frame, so
/// the leading icon column lines up across the entire list. History rows
/// pass `nil` as the system image to render a transparent placeholder
/// (text aligns with the folder header's text above).
struct SidebarView2: View {
    @Binding var selection: String?
    @Environment(SessionManager.self) private var manager
    /// Folders the user has manually collapsed. Default is expanded; we
    /// track collapsed-set rather than expanded-set so newly-appearing
    /// folders (after a fresh session lands) are open by default.
    @State private var collapsedFolders: Set<String> = []

    /// Sentinel selection value for the "New Session" tab.
    static let newSessionTag = "__new_session__"
    /// Sentinel selection value for the Archive page (list of soft-deleted
    /// sessions, recoverable via unarchive).
    static let archiveTag = "__archive__"
    #if DEBUG
    /// Sentinel selection value used by the dev-only Transcript Demo tab.
    /// Reserved by the double-underscore prefix; real session IDs are UUIDs.
    static let transcriptDemoTag = "__transcript_demo__"
    /// Sentinel for the Transcript Stress tab (long-document perf test).
    static let transcriptStressTag = "__transcript_stress__"
    /// Sentinel for the Transcript Perf tab — focused repro for the
    /// "expanded diff scroll drops frames" bug. Renders one tool group
    /// whose lone fileEdit child carries a many-screen diff body. See
    /// `TranscriptPerfDemoView` + `Transcript2PerfLog` for the trace
    /// scaffold the tab installs while mounted.
    static let transcriptPerfTag = "__transcript_perf__"
    /// Sentinel for the Permission Cards preview grid — every
    /// `PermissionCardKind` rendered side-by-side in a fixed grid.
    static let permissionCardsDemoTag = "__permission_cards_demo__"
    /// Sentinel for the Permission Session demo — real transcript +
    /// input bar with a floating control panel that flips the permission
    /// card on/off against the mocked session's runtime.
    static let permissionSessionDemoTag = "__permission_session_demo__"
    #endif

    var body: some View {
        List(selection: $selection) {
            SidebarItemRow(title: "New Session", systemImage: "square.and.pencil")
                .tag(Self.newSessionTag)
                .listRowInsets(Self.fixedRowInsets)
            SidebarItemRow(title: "Archive", systemImage: "archivebox")
                .tag(Self.archiveTag)
                .listRowInsets(Self.fixedRowInsets)
            #if DEBUG
            SidebarItemRow(title: "Transcript Demo", systemImage: "doc.text.image")
                .tag(Self.transcriptDemoTag)
                .listRowInsets(Self.fixedRowInsets)
            SidebarItemRow(title: "Transcript Stress", systemImage: "speedometer")
                .tag(Self.transcriptStressTag)
                .listRowInsets(Self.fixedRowInsets)
            SidebarItemRow(title: "Transcript Perf", systemImage: "waveform.path.ecg")
                .tag(Self.transcriptPerfTag)
                .listRowInsets(Self.fixedRowInsets)
            SidebarItemRow(
                title: "Permission Cards Demo", systemImage: "hand.raised.fill"
            )
            .tag(Self.permissionCardsDemoTag)
            .listRowInsets(Self.fixedRowInsets)
            SidebarItemRow(
                title: "Permission Session Demo",
                systemImage: "hand.raised.app.fill"
            )
            .tag(Self.permissionSessionDemoTag)
            .listRowInsets(Self.fixedRowInsets)
            #endif

            ForEach(groupedRecords) { group in
                SidebarFolderHeader(
                    name: group.folderName,
                    isExpanded: !collapsedFolders.contains(group.folderName),
                    onToggle: { toggleFolder(group.folderName) }
                )
                .listRowInsets(Self.folderHeaderInsets)
                .selectionDisabled()

                if !collapsedFolders.contains(group.folderName) {
                    ForEach(group.records) { record in
                        SidebarHistoryRow(record: record)
                            .tag(record.sessionId)
                            .listRowInsets(Self.historyRowInsets)
                            .contextMenu {
                                Button(String(localized: "Archive")) {
                                    archive(record.sessionId)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
    }

    /// Shared horizontal insets keep the icon column aligned across all
    /// three row types; vertical insets differ to give history rows a
    /// tighter rhythm without shrinking the font.
    private static let fixedRowInsets = EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8)
    private static let folderHeaderInsets = EdgeInsets(top: 10, leading: 4, bottom: 4, trailing: 8)
    private static let historyRowInsets = EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 8)

    /// Soft-delete the row and, if it was the active selection, bounce
    /// the user back to the New Session tab so the detail pane doesn't
    /// keep rendering a session that no longer appears in the list.
    private func archive(_ sessionId: String) {
        if selection == sessionId {
            selection = Self.newSessionTag
        }
        manager.archive(sessionId)
    }

    private func toggleFolder(_ name: String) {
        withAnimation(.smooth(duration: 0.25)) {
            if collapsedFolders.contains(name) {
                collapsedFolders.remove(name)
            } else {
                collapsedFolders.insert(name)
            }
        }
    }

    /// Grouped list derived from `manager.records`. Computed reads the
    /// observable directly, so updates recompute automatically without manual reload.
    private var groupedRecords: [ProjectGroup2] {
        let buckets = Dictionary(grouping: manager.records) { $0.groupingFolderName ?? "Unknown" }
        return buckets.map { folder, items in
            ProjectGroup2(
                folderName: folder,
                records: items.sorted { $0.lastActiveAt > $1.lastActiveAt }
            )
        }
        .sorted {
            guard let a = $0.records.first, let b = $1.records.first else { return false }
            return a.lastActiveAt > b.lastActiveAt
        }
    }
}

private struct ProjectGroup2: Identifiable {
    var id: String { folderName }
    let folderName: String
    let records: [SessionRecord]
}

// MARK: - Atoms

/// Fixed-frame icon slot shared by every sidebar row. Renders the named
/// SF Symbol when present, or an empty (transparent) frame when nil —
/// the latter lets history rows reserve the same horizontal column as
/// rows that do have an icon, so their text lines up with the folder
/// header's text above.
///
/// Access is `internal` rather than `private` so the snapshot test
/// (`SidebarView2SnapshotTests`) can compose the same row visuals into
/// a plain `VStack` — SwiftUI's `.listStyle(.sidebar)` is backed by
/// `NSOutlineView` and refuses to render rows in the offscreen test
/// window. The struct stays file-scoped in practice; production code
/// never references it from outside this file.
struct SidebarIcon: View {
    static let slotWidth: CGFloat = 16
    let systemImage: String?

    var body: some View {
        ZStack {
            if let name = systemImage {
                Image(systemName: name)
                    .font(.system(size: 12, weight: .regular))
            }
        }
        .frame(width: Self.slotWidth, height: Self.slotWidth)
    }
}

// MARK: - Rows

/// Fixed top-of-sidebar entry (New Session, Transcript Demo, ...). Behaves
/// like a normal selectable List row; its `.tag` is supplied by the caller.
/// `internal` only so the snapshot test can mount it; see `SidebarIcon`.
struct SidebarItemRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            SidebarIcon(systemImage: systemImage)
            Text(title)
        }
        .lineLimit(1)
    }
}

/// Folder-grouping header row. Same row chrome as `SidebarItemRow` (so
/// icons + text align), but the whole row is rendered in the secondary
/// foreground to read as a section label rather than a destination. Tap
/// anywhere on the row to collapse / expand — the chevron rotates and
/// the children inside the surrounding `ForEach` animate in/out.
struct SidebarFolderHeader: View {
    let name: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                SidebarIcon(systemImage: "folder")
                Text(name)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
}

/// History entry inside a folder group. The leading icon column hosts
/// `SidebarSessionStatusIndicator` — three breathing dots while the
/// session is running, a small blue dot when there are unread messages
/// and nothing is running, otherwise a transparent placeholder so the
/// title text still aligns with the folder header's text above.
///
/// The title `Text` is shimmered while the session is generating its
/// LLM-derived title (the row already shows the first-message-derived
/// placeholder, so there is always something to shimmer). When the
/// generated title lands, the text crossfades into the new value.
struct SidebarHistoryRow: View {
    let record: SessionRecord
    @Environment(SessionManager.self) private var manager

    var body: some View {
        let session = manager.existingSession(record.sessionId)
        HStack(spacing: 6) {
            SidebarSessionStatusIndicator(
                isRunning: session?.isRunning ?? false,
                hasUnread: session?.hasUnread ?? false
            )
            Text(record.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .shimmer(active: session?.isGeneratingTitle == true)
                .animation(.easeIn(duration: 0.25), value: record.title)
        }
    }
}

// MARK: - Status indicators

/// Leading icon-slot occupant for a history row. Drops into the same
/// 16pt frame New Session / folder-header rows use for their SF
/// Symbol, so the indicator column aligns vertically with the icon
/// column above. When neither flag is set the slot stays transparent
/// — same role the empty `SidebarIcon(systemImage: nil)` placeholder
/// used to play.
///
/// Precedence: running wins over unread — once a session goes idle and
/// unread accumulates, the dot replaces the dots. They are never
/// rendered simultaneously.
struct SidebarSessionStatusIndicator: View {
    let isRunning: Bool
    let hasUnread: Bool

    var body: some View {
        ZStack {
            if isRunning {
                SidebarLoadingDots()
            } else if hasUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: SidebarIcon.slotWidth, height: SidebarIcon.slotWidth)
    }
}

/// SwiftUI port of the transcript's `LoadingPillLayout` — three
/// breathing dots whose opacities cycle in a left-to-right wave. The
/// timing constants (`period`, `phaseStagger`, `dotSize`) are copied
/// verbatim from `BlockCellView+SubviewPlan.swift` so the sidebar pill
/// and the transcript pill breathe in lockstep when the same session
/// is visible in both places.
///
/// Geometry is squeezed to fit the 16pt `SidebarIcon.slotWidth` — dot
/// size matches the transcript (3pt) but the inter-dot gap shrinks
/// (4pt → 1.5pt) so 3 × 3 + 2 × 1.5 = 12pt reads as a compact pip
/// cluster inside the slot.
struct SidebarLoadingDots: View {
    static let dotSize: CGFloat = 3
    static let dotGap: CGFloat = 1.5
    /// Full breath cycle — matches transcript.
    static let period: Double = 1.2
    /// Per-dot phase offset — matches transcript.
    static let phaseStagger: Double = 0.18
    /// Higher than transcript's 0.25: at 3pt the dots need a larger
    /// floor or the breath's low point falls below ~1.6:1 contrast in
    /// dark mode and the dots visibly disappear.
    static let minOpacity: Double = 0.45

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: Self.dotGap) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.primary)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .opacity(Self.opacity(at: t, staggerIndex: index))
                }
            }
        }
    }

    /// Smooth sine breath in `[minOpacity, 1]`, identical shape to the
    /// transcript's `(1 - cos(2π t)) / 2`. Per-dot `staggerIndex`
    /// shifts the phase so the wave crest sweeps left-to-right.
    static func opacity(at time: Double, staggerIndex: Int) -> Double {
        let shifted = time - Double(staggerIndex) * phaseStagger
        let normalized = shifted.truncatingRemainder(dividingBy: period) / period
        let nonNegative = normalized < 0 ? normalized + 1 : normalized
        let s = (1 - cos(2 * .pi * nonNegative)) / 2
        return minOpacity + (1 - minOpacity) * s
    }
}

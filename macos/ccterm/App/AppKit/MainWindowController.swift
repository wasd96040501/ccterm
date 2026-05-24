import AppKit
import SwiftUI

/// Window controller for the AppKit-rooted main window. Replaces
/// SwiftUI's `Window("ccterm")` scene — the window is created in
/// `applicationDidFinishLaunching` so the transcript's mount and
/// frame-change events flow through AppKit's source phase without
/// SwiftUI commit-pass interleaving.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    let model: MainSelectionModel
    let appState: AppState
    let searchBus: TranscriptSearchBus

    private let splitController: MainSplitViewController
    private var searchToolbarItem: NSSearchToolbarItem?
    /// Bridge object that pipes SwiftUI `TranscriptSearchBus` →
    /// AppKit `NSSearchField` focus + query plumbing.
    private var searchBridge: TranscriptSearchToolbarBridge?
    private var selectionObservationTask: Task<Void, Never>?

    private enum ItemID {
        static let projectChip = NSToolbarItem.Identifier("ccterm.projectChip")
        static let search = NSToolbarItem.Identifier("ccterm.transcriptSearch")
        static let archiveFilter = NSToolbarItem.Identifier("ccterm.archiveFilter")
    }

    init(model: MainSelectionModel, appState: AppState, searchBus: TranscriptSearchBus) {
        self.model = model
        self.appState = appState
        self.searchBus = searchBus

        splitController = MainSplitViewController(
            model: model, appState: appState, searchBus: searchBus)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "ccterm"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // Translucent window so the detail pane's behind-window vibrancy
        // (see `DetailRouterViewController`) and the source-list sidebar
        // can sample the desktop, instead of every pane sitting on the
        // flat opaque `windowBackgroundColor` the OS paints by default.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 540)
        window.contentViewController = splitController

        super.init(window: window)
        // NSWindowController defaults `shouldCascadeWindows` to true,
        // which moves the window on `showWindow(_:)` based on the last
        // displayed window's origin — racing with the autosaved frame.
        // Disable so the saved frame is the only source of truth.
        shouldCascadeWindows = false
        // Probe defaults before turning autosave on so we can detect a
        // first launch (no saved frame) and center the default frame.
        // `setFrameAutosaveName` synchronously reads the saved frame
        // and applies it; nothing to do here if it landed.
        let autosaveKey = "NSWindow Frame \(Self.frameAutosaveName)"
        let hadSavedFrame = UserDefaults.standard.string(forKey: autosaveKey) != nil
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !hadSavedFrame {
            window.center()
        }
        installToolbar()
    }

    private static let frameAutosaveName = "MainWindow"

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { selectionObservationTask?.cancel() }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "ccterm.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
        // Project chip + archive filter are both conditional — driven
        // by the current selection. Sync initial state, then re-evaluate
        // on selection changes via Observation.
        updateProjectChipPresence()
        updateArchiveFilterPresence()
        startSelectionObservation()
    }

    /// Whether the current sidebar selection is the Archive tab.
    /// Controls visibility of the folder-filter toolbar item.
    private var isArchiveSelected: Bool {
        model.selection == .archive
    }

    /// Whether the current sidebar selection is a real history session,
    /// as opposed to one of the sidebar tabs (New Session / Archive /
    /// DEBUG demos). The `MainSelection` enum makes this a direct case
    /// match — the compiler enforces that any new selection case is
    /// considered here.
    private var isHistorySession: Bool {
        if case .session = model.selection { return true }
        return false
    }

    /// Insert or remove the project-chip toolbar item to match the
    /// current selection. NSToolbar caches the hosted SwiftUI's
    /// measured size and won't re-query on content change, so when
    /// transitioning into a (different) history session we always
    /// remove-then-insert to force a fresh measurement of the new
    /// session's content. Wrapped in a zero-duration animation context
    /// so NSToolbar's default fade-in/out doesn't fire.
    ///
    /// The chip must sit **after** the `.sidebarTrackingSeparator` so
    /// it belongs to the content (detail) section of the toolbar, not
    /// the sidebar section. macOS 11+ groups contiguous items on each
    /// side of the separator into a single capsule background — placing
    /// the chip on the sidebar side puts it inside the traffic-light /
    /// sidebar-toggle capsule, and worse, sidebar-collapse hides the
    /// whole sidebar group along with it.
    private func updateProjectChipPresence() {
        guard let toolbar = window?.toolbar else { return }
        let currentIndex = toolbar.items.firstIndex {
            $0.itemIdentifier == ItemID.projectChip
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if let idx = currentIndex {
                toolbar.removeItem(at: idx)
            }
            if isHistorySession {
                let separatorIndex = toolbar.items.firstIndex {
                    $0.itemIdentifier == .sidebarTrackingSeparator
                }
                // Fall back to position 0 only if the separator isn't
                // present (shouldn't happen — it's in default items).
                let insertAt = separatorIndex.map { $0 + 1 } ?? 0
                toolbar.insertItem(withItemIdentifier: ItemID.projectChip, at: insertAt)
            }
        }
    }

    private func startSelectionObservation() {
        selectionObservationTask?.cancel()
        selectionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.model.selection
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.updateProjectChipPresence()
            self.updateArchiveFilterPresence()
            self.startSelectionObservation()
        }
    }

    /// Insert or remove the archive folder-filter toolbar item to match
    /// the current selection. Mirrors `updateProjectChipPresence` —
    /// placed after the `.sidebarTrackingSeparator` so it belongs to
    /// the detail half of the toolbar, and wrapped in a zero-duration
    /// animation context so NSToolbar's default fade-in/out doesn't
    /// fire when the user flips into / out of the Archive tab.
    private func updateArchiveFilterPresence() {
        guard let toolbar = window?.toolbar else { return }
        let currentIndex = toolbar.items.firstIndex {
            $0.itemIdentifier == ItemID.archiveFilter
        }
        let shouldShow = isArchiveSelected
        if shouldShow == (currentIndex != nil) { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if let idx = currentIndex {
                toolbar.removeItem(at: idx)
            }
            if shouldShow {
                // Insert immediately before the search item so the
                // filter button sits to the search field's left.
                let searchIndex = toolbar.items.firstIndex {
                    $0.itemIdentifier == ItemID.search
                }
                let insertAt = searchIndex ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: ItemID.archiveFilter, at: insertAt)
            }
        }
    }

    func makeSearchBridgeIfNeeded(field: NSSearchField) -> TranscriptSearchToolbarBridge {
        if let existing = searchBridge { return existing }
        let bridge = TranscriptSearchToolbarBridge(
            searchField: field,
            searchBus: searchBus,
            controllerProvider: { [weak self] in
                guard let sid = self?.model.effectiveSessionId,
                    let session = self?.appState.sessionManager.existingSession(sid)
                else { return nil }
                return session.controller
            })
        searchBridge = bridge
        return bridge
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.toggleSidebar` + `.sidebarTrackingSeparator` are
        // system-provided items: NSToolbar synthesizes them, supplies
        // the standard icon, and wires the action to
        // `NSSplitViewController.toggleSidebar(_:)` via the responder
        // chain — they never come through `itemForItemIdentifier`.
        //
        // Project chip is inserted/removed imperatively by
        // `updateProjectChipPresence()` based on the current selection,
        // so it's NOT in the default identifiers — only search is.
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            ItemID.projectChip,
            ItemID.search,
            ItemID.archiveFilter,
            .flexibleSpace,
            .space,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.projectChip:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let host = NSHostingView(
                rootView: TranscriptProjectChip(
                    model: model,
                    sessionManager: appState.sessionManager
                )
            )
            host.translatesAutoresizingMaskIntoConstraints = false
            // `intrinsicContentSize` makes the hosting view's natural
            // size track the SwiftUI body's `fittingSize`. Toolbar
            // auto-measures via this; do NOT set the deprecated
            // `item.minSize` / `item.maxSize`.
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.visibilityPriority = .high
            return item
        case ItemID.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = String(localized: "Find in transcript")
            item.resignsFirstResponderWithCancel = true
            let bridge = makeSearchBridgeIfNeeded(field: item.searchField)
            item.searchField.delegate = bridge
            item.searchField.target = bridge
            item.searchField.action = #selector(TranscriptSearchToolbarBridge.searchAction(_:))
            searchToolbarItem = item
            return item
        case ItemID.archiveFilter:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let host = NSHostingView(
                rootView: ArchiveFilterToolbarButton(
                    model: model,
                    sessionManager: appState.sessionManager
                )
            )
            host.translatesAutoresizingMaskIntoConstraints = false
            // Toolbar auto-measures via the hosted view's
            // `intrinsicContentSize`, which SwiftUI drives off the
            // body's `fittingSize`. Same pattern as the project chip
            // above.
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.label = String(localized: "Filter by folder")
            item.toolTip = String(localized: "Filter by folder")
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }
}

// MARK: - Archive filter button

/// Trailing toolbar item shown only when the Archive tab is selected.
/// SwiftUI Button + popover hosted via `NSHostingView`. Reads/writes
/// `MainSelectionModel.archiveSelectedFolderPath` so picking a folder
/// in the popover updates `ArchiveView`'s filtered list immediately;
/// reads `SessionManager.archivedFolderOptions` for the popover rows.
private struct ArchiveFilterToolbarButton: View {
    @Bindable var model: MainSelectionModel
    let sessionManager: SessionManager

    @State private var isPopoverPresented: Bool = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(
                systemName: model.archiveSelectedFolderPath == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .help(Text("Filter by folder"))
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            FolderFilterPickerView(
                folders: sessionManager.archivedFolderOptions,
                selectedPath: model.archiveSelectedFolderPath,
                onSelect: { path in
                    model.archiveSelectedFolderPath = path
                    isPopoverPresented = false
                }
            )
        }
    }
}

// MARK: - Project chip view

/// Leading toolbar item: dirName (semibold) over branchName (secondary).
/// SwiftUI inside an `NSHostingView` — the body's `fittingSize`
/// drives the hosting view's `intrinsicContentSize`, so the toolbar
/// slot auto-resizes to content. `.animation()` makes the width change
/// smoothly when switching sessions, and gates the whole VStack to an
/// empty body for non-history sessions so the slot collapses entirely.
private struct TranscriptProjectChip: View {
    @Bindable var model: MainSelectionModel
    let sessionManager: SessionManager

    private var session: Session? {
        guard case .session(let sid) = model.selection else { return nil }
        return sessionManager.existingSession(sid)
    }

    private var dirName: String? {
        guard let path = session?.originPath, !path.isEmpty else { return nil }
        let comp = (path as NSString).lastPathComponent
        return comp.isEmpty ? nil : comp
    }

    /// Synchronous branch lookup — `.git/HEAD` is a small file read,
    /// so doing it during body evaluation keeps the chip's first
    /// measurement correct. Doing it via `.task` (async) would cause
    /// the toolbar to measure the chip BEFORE the branch line was
    /// added, leaving the slot at the no-branch width.
    private var branchName: String? {
        if let cwd = session?.cwd,
            let probed = GitUtils.currentBranch(at: cwd),
            !probed.isEmpty
        {
            return probed
        }
        if let session, let b = session.worktreeBranch, !b.isEmpty { return b }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dirName {
                Text(dirName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let branchName {
                Text(branchName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 220, alignment: .leading)
    }
}

// MARK: - Search bridge

/// Wires the AppKit `NSSearchField` in the window toolbar to:
/// - `TranscriptSearchBus` (for ⌘F focus requests)
/// - the live session's `Transcript2Controller` (for query / next /
///   previous nav)
///
/// Mirrors the SwiftUI behavior in `TranscriptSearchToolbar`:
/// - typing updates the controller's search query
/// - Return advances to the next match
/// - Shift+Return steps to the previous match
/// - ⌘F (via `TranscriptSearchBus.focusRequestCounter`) takes focus
@MainActor
final class TranscriptSearchToolbarBridge: NSObject, NSSearchFieldDelegate {
    private weak var searchField: NSSearchField?
    private let searchBus: TranscriptSearchBus
    private let controllerProvider: () -> Transcript2Controller?
    private var focusObservationTask: Task<Void, Never>?
    private var lastFocusCounter: Int

    init(
        searchField: NSSearchField,
        searchBus: TranscriptSearchBus,
        controllerProvider: @escaping () -> Transcript2Controller?
    ) {
        self.searchField = searchField
        self.searchBus = searchBus
        self.controllerProvider = controllerProvider
        self.lastFocusCounter = searchBus.focusRequestCounter
        super.init()
        startFocusObservation()
    }

    deinit { focusObservationTask?.cancel() }

    private func startFocusObservation() {
        focusObservationTask?.cancel()
        focusObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.searchBus.focusRequestCounter
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            let counter = self.searchBus.focusRequestCounter
            if counter != self.lastFocusCounter {
                self.lastFocusCounter = counter
                self.focusSearchField()
            }
            self.startFocusObservation()
        }
    }

    private func focusSearchField() {
        guard let field = searchField, let window = field.window else { return }
        window.makeFirstResponder(field)
    }

    @objc func searchAction(_ sender: NSSearchField) {
        controllerProvider()?.runSearch(sender.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        controllerProvider()?.runSearch(field.stringValue)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        // Return → next hit. Shift+Return → previous hit. The text
        // view's `selectAll(_:)` selector covers the Shift+Return
        // case because AppKit collapses both into `insertNewline:`
        // — discriminate via the current event modifiers.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shifted {
                controllerProvider()?.previousSearchHit()
            } else {
                controllerProvider()?.nextSearchHit()
            }
            return true
        }
        return false
    }
}

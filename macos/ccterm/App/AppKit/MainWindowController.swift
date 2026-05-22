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
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 540)
        window.contentViewController = splitController
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)
        installToolbar()
    }

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
        // Project chip is conditionally present (only for history
        // sessions). Sync initial state then re-evaluate on selection
        // changes via Observation.
        updateProjectChipPresence()
        startSelectionObservation()
    }

    /// Whether the current sidebar selection is a real history session,
    /// as opposed to one of the sentinel tabs (New Session / Archive /
    /// DEBUG demos). Listed explicitly against `SidebarView2`'s
    /// constants so adding a new tab requires a deliberate update here.
    private var isHistorySession: Bool {
        guard let sid = model.selectedSessionId else { return false }
        return !Self.sentinelTags.contains(sid)
    }

    private static let sentinelTags: Set<String> = {
        var tags: Set<String> = [
            SidebarView2.newSessionTag,
            SidebarView2.archiveTag,
        ]
        #if DEBUG
        tags.formUnion([
            SidebarView2.transcriptDemoTag,
            SidebarView2.transcriptStressTag,
            SidebarView2.transcriptPerfTag,
            SidebarView2.permissionCardsDemoTag,
            SidebarView2.permissionSessionDemoTag,
        ])
        #endif
        return tags
    }()

    /// Insert or remove the project-chip toolbar item to match the
    /// current selection. NSToolbar caches the hosted SwiftUI's
    /// measured size and won't re-query on content change, so when
    /// transitioning into a (different) history session we always
    /// remove-then-insert to force a fresh measurement of the new
    /// session's content. Wrapped in a zero-duration animation context
    /// so NSToolbar's default fade-in/out doesn't fire.
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
                toolbar.insertItem(withItemIdentifier: ItemID.projectChip, at: 0)
            }
        }
    }

    private func startSelectionObservation() {
        selectionObservationTask?.cancel()
        selectionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.model.selectedSessionId
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.updateProjectChipPresence()
            self.startSelectionObservation()
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
        // Project chip is inserted/removed imperatively by
        // `updateProjectChipPresence()` based on the current selection,
        // so it's NOT in the default identifiers — only search is.
        [.flexibleSpace, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.projectChip, ItemID.search, .flexibleSpace, .space]
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
        default:
            return nil
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
        guard let sid = model.selectedSessionId else { return nil }
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

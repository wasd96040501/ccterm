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
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 540)
        window.contentViewController = splitController
        window.setFrameAutosaveName("MainWindow")
        // The transcript runs flush to the window's top edge. Pair
        // `hiddenTitleBar` + `.unifiedCompact` toolbar style + hidden
        // toolbar background so the toolbar band doesn't paint a strip
        // over the transcript. See `NativeTranscript2/CLAUDE.md`
        // (§6.5 Search) for the matching SwiftUI modifier set.
        window.styleMask.insert(.fullSizeContentView)

        super.init(window: window)
        installToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "ccterm.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
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
        [ItemID.projectChip, .flexibleSpace, ItemID.search]
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
                .frame(maxWidth: 200, alignment: .leading)
            )
            host.frame.size = NSSize(width: 200, height: 36)
            item.view = host
            item.minSize = NSSize(width: 80, height: 28)
            item.maxSize = NSSize(width: 220, height: 36)
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

/// SwiftUI view hosted inside the leading toolbar item. Mirrors the
/// `dirName` / `branchName` pair `ChatHistoryView`'s `.toolbar`
/// modifier used to surface in the SwiftUI version.
private struct TranscriptProjectChip: View {
    @Bindable var model: MainSelectionModel
    let sessionManager: SessionManager
    @State private var probedBranch: String?

    private var session: Session? {
        guard let sid = model.effectiveSessionId else { return nil }
        return sessionManager.existingSession(sid)
    }

    private var dirName: String? {
        guard let path = session?.originPath, !path.isEmpty else { return nil }
        let comp = (path as NSString).lastPathComponent
        return comp.isEmpty ? nil : comp
    }

    private var branchName: String? {
        if let probed = probedBranch, !probed.isEmpty { return probed }
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
        .task(id: session?.cwd) {
            probedBranch = session?.cwd.flatMap(GitUtils.currentBranch(at:))
        }
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

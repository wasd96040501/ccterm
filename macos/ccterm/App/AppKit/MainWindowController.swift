import AppKit
import Combine

/// Thin window controller for the AppKit-rooted main window. Owns
/// window-level chrome (frame autosave, title, toolbar) and forwards
/// every semantic event through `MainWindowControllerDelegate` — the
/// controller never reaches into the `SelectionStore` / `SessionManager`
/// / `AppContext` itself. Routing decisions belong to the coordinator.
///
/// The toolbar hosts three items: a `ProjectChipView` (leading), an
/// `NSSearchToolbarItem` (trailing), and an `ArchiveFilterButton` shown
/// only when the Archive tab is selected. Insertion and removal of the
/// two conditional items is imperative (`updateProjectChip(with:)` /
/// `updateArchiveFilterPresence(...)`), driven top-down by the
/// coordinator when the selection changes.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {

    let windowContext: WindowContext
    weak var delegate: MainWindowControllerDelegate?

    private let splitViewController: MainSplitViewController

    private var searchToolbarItem: NSSearchToolbarItem?
    private var projectChipItem: NSToolbarItem?
    private var archiveFilterItem: NSToolbarItem?
    private var projectChipView: ProjectChipView?
    private var archiveFilterButton: ArchiveFilterButton?

    private var searchBusCancellable: AnyCancellable?

    private enum ItemID {
        static let projectChip = NSToolbarItem.Identifier("ccterm.projectChip")
        static let search = NSToolbarItem.Identifier("ccterm.transcriptSearch")
        static let archiveFilter = NSToolbarItem.Identifier("ccterm.archiveFilter")
    }

    private static let frameAutosaveName = "MainWindow"

    init(windowContext: WindowContext, splitViewController: MainSplitViewController) {
        self.windowContext = windowContext
        self.splitViewController = splitViewController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "ccterm")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 540)
        window.contentViewController = splitViewController

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

        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func windowDidLoad() {
        super.windowDidLoad()
        installToolbar()
        // ⌘F menu items go through the searchBus. The window controller
        // owns the search field, so it's the natural sink for focus
        // requests.
        searchBusCancellable = windowContext.searchBus.focusRequests
            .sink { [weak self] _ in
                guard let self else { return }
                self.focusSearchField()
            }
    }

    // MARK: - Public API (coordinator surface)

    /// Bring the window to front and activate the app.
    func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Move first-responder to the toolbar's search field. No-op if the
    /// window or the field isn't installed yet.
    func focusSearchField() {
        guard let field = searchToolbarItem?.searchField, let window else { return }
        window.makeFirstResponder(field)
    }

    /// Set the search field's text without firing the delegate. Used
    /// by the coordinator when the current session changes (the query
    /// belongs to the session, not the window).
    func setSearchQuery(_ query: String) {
        guard let field = searchToolbarItem?.searchField else { return }
        field.stringValue = query
    }

    /// Insert / remove the project-chip toolbar item to match the
    /// current selection. `nil` removes the chip; a non-nil value
    /// inserts it (if missing) and hands the view model down to the
    /// hosted `ProjectChipView` via `configure(with:)`. Toolbar
    /// mutations are wrapped in a zero-duration animation context so
    /// NSToolbar's default fade-in/out doesn't fire.
    func updateProjectChip(with viewModel: ProjectChipViewModel?) {
        if let viewModel {
            updateProjectChipPresence(present: true)
            projectChipView?.configure(with: viewModel)
        } else {
            updateProjectChipPresence(present: false)
        }
    }

    /// Toggle the archive-filter toolbar item's visibility and, when
    /// shown, hand it the currently-available folder options + the
    /// active filter. The item slots in immediately before the search
    /// item, matching the previous SwiftUI layout.
    func updateArchiveFilterPresence(
        show: Bool,
        options: [SessionManager.ArchivedFolder],
        selectedPath: String?
    ) {
        guard let toolbar = window?.toolbar else { return }
        let currentIndex = toolbar.items.firstIndex {
            $0.itemIdentifier == ItemID.archiveFilter
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if show {
                if currentIndex == nil {
                    // Insert immediately before the search item so the
                    // filter button sits to the search field's left.
                    let searchIndex = toolbar.items.firstIndex {
                        $0.itemIdentifier == ItemID.search
                    }
                    let insertAt = searchIndex ?? toolbar.items.count
                    toolbar.insertItem(withItemIdentifier: ItemID.archiveFilter, at: insertAt)
                }
            } else if let idx = currentIndex {
                toolbar.removeItem(at: idx)
            }
        }
        if show {
            archiveFilterButton?.configure(options: options, selectedPath: selectedPath)
        }
    }

    // MARK: - Toolbar installation

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "ccterm.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
    }

    /// Imperative insert/remove of the project chip. The chip must sit
    /// **after** the `.sidebarTrackingSeparator` so it belongs to the
    /// content (detail) section of the toolbar, not the sidebar section.
    /// macOS 11+ groups contiguous items on each side of the separator
    /// into a single capsule background — placing the chip on the
    /// sidebar side puts it inside the traffic-light / sidebar-toggle
    /// capsule, and sidebar-collapse hides the whole sidebar group
    /// along with it.
    private func updateProjectChipPresence(present: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let currentIndex = toolbar.items.firstIndex {
            $0.itemIdentifier == ItemID.projectChip
        }
        if present == (currentIndex != nil) { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if present {
                let separatorIndex = toolbar.items.firstIndex {
                    $0.itemIdentifier == .sidebarTrackingSeparator
                }
                // Fall back to position 0 only if the separator isn't
                // present (shouldn't happen — it's in default items).
                let insertAt = separatorIndex.map { $0 + 1 } ?? 0
                toolbar.insertItem(withItemIdentifier: ItemID.projectChip, at: insertAt)
            } else if let idx = currentIndex {
                toolbar.removeItem(at: idx)
            }
        }
    }

    // MARK: - Actions

    @objc private func searchAction(_ sender: NSSearchField) {
        delegate?.mainWindowController(self, searchQueryDidChange: sender.stringValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.toggleSidebar` + `.sidebarTrackingSeparator` are
        // system-provided items: NSToolbar synthesizes them, supplies
        // the standard icon, and wires the action to
        // `NSSplitViewController.toggleSidebar(_:)` via the responder
        // chain — they never come through `itemForItemIdentifier`.
        //
        // Project chip and archive filter are inserted/removed
        // imperatively based on the current selection, so they're NOT
        // in the default identifiers.
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
            let chip = ProjectChipView(frame: .zero)
            item.view = chip
            item.visibilityPriority = .high
            item.label = String(localized: "Project")
            projectChipItem = item
            projectChipView = chip
            return item
        case ItemID.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = String(localized: "Find in transcript")
            item.resignsFirstResponderWithCancel = true
            item.searchField.target = self
            item.searchField.action = #selector(searchAction(_:))
            item.searchField.delegate = self
            searchToolbarItem = item
            return item
        case ItemID.archiveFilter:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = ArchiveFilterButton(frame: .zero)
            button.onSelect = { [weak self] path in
                guard let self else { return }
                self.delegate?.mainWindowController(
                    self, archiveFilterDidSelectFolderPath: path)
            }
            item.view = button
            item.label = String(localized: "Filter by folder")
            item.toolTip = String(localized: "Filter by folder")
            item.visibilityPriority = .high
            archiveFilterItem = item
            archiveFilterButton = button
            return item
        default:
            return nil
        }
    }

    nonisolated deinit {}
}

// MARK: - NSSearchFieldDelegate

extension MainWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        delegate?.mainWindowController(self, searchQueryDidChange: field.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        // Return → next hit. Shift+Return → previous hit. AppKit
        // collapses both into `insertNewline:` — discriminate via the
        // current event's modifier flags. Returning `true` swallows the
        // newline (the search field stays put, no beep).
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            delegate?.mainWindowController(self, searchDidRequestNext: !shifted)
            return true
        }
        return false
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        delegate?.mainWindowControllerWillClose(self)
    }
}

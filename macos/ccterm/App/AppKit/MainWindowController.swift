import AppKit

/// Window controller for the AppKit-rooted main window. The window is
/// created in `applicationDidFinishLaunching` rather than declared as a
/// SwiftUI `Window` scene, so everything mounted in it runs in AppKit's
/// source phase without SwiftUI commit-pass interleaving.
///
/// Owns the toolbar, laid out as Xcode's over the editors: back and forward
/// through the active editor's history, then the project the reader is in and
/// its git branch. Nothing sits over the sidebar, which never collapses, so
/// there is no sidebar button either.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let splitController: MainSplitViewController
    private let titleView = MainWindowTitleView()

    /// The project the title shows, and the task following its branch.
    private var project: URL?
    private var branchTask: Task<Void, Never>?

    init(library: LibraryStore) {
        splitController = MainSplitViewController(library: library)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "ccterm"
        window.titlebarAppearsTransparent = true
        // The toolbar's title item shows it instead (`MainWindowTitleView`);
        // `title` still names the window in the Window menu and Mission Control.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 970, height: 540)  // the sidebar's 290 beside the editors' 680
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
        splitController.delegate = self
        installToolbar()
    }

    private static let frameAutosaveName = "MainWindow"

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

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.sidebarTrackingSeparator` is system-provided: it keeps the items
        // after it over the editors, whatever the sidebar's width.
        [.sidebarTrackingSeparator, .navigation, .projectTitle, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation: navigationItem()
        case .projectTitle: titleItem()
        default: nil
        }
    }

    /// Back and forward as one control, as Xcode's and Finder's: a momentary
    /// segmented group, each segment an item of its own that the split validates.
    private func navigationItem() -> NSToolbarItem {
        let group = NSToolbarItemGroup(itemIdentifier: .navigation)
        return group
    }

    private func titleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .projectTitle)
        item.view = titleView
        return item
    }
}

extension MainWindowController: MainSplitViewControllerDelegate {
    func mainSplitViewController(_ split: MainSplitViewController, didShowProjectAt url: URL?) {}
}

extension NSToolbarItem.Identifier {
    fileprivate static let navigation = NSToolbarItem.Identifier("ccterm.main.navigation")
    fileprivate static let projectTitle = NSToolbarItem.Identifier("ccterm.main.projectTitle")
}

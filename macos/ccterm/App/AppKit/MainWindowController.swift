import AppKit

/// Window controller for the AppKit-rooted main window. The window is
/// created in `applicationDidFinishLaunching` rather than declared as a
/// SwiftUI `Window` scene, so everything mounted in it runs in AppKit's
/// source phase without SwiftUI commit-pass interleaving.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let splitController: MainSplitViewController

    init(library: LibraryStore) {
        splitController = MainSplitViewController(library: library)
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
        // `.toggleSidebar` + `.sidebarTrackingSeparator` are
        // system-provided items: NSToolbar synthesizes them, supplies
        // the standard icon, and wires the action to
        // `NSSplitViewController.toggleSidebar(_:)` via the responder
        // chain — they never come through `itemForItemIdentifier`.
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        nil
    }
}

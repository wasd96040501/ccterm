import AppKit
import SwiftUI

/// AppKit-rooted window controller for the Settings panel. Replaces
/// the previous SwiftUI `Settings { … }` scene whose internal NSWindow
/// occasionally resurfaced at cold start (OS-level window state
/// restoration outside our control). The contents stay pure SwiftUI —
/// `SettingsView` is hosted via `NSHostingController` — but the
/// NSWindow lifecycle is owned by us: lazy-created on the first
/// `showWindow(_:)`, `isRestorable = false`, ⌘, routed through
/// `AppCommands` → `AppDelegate.showSettingsWindow()`.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        // Recipe to make the SwiftUI `NavigationSplitView` sidebar bleed
        // edge-to-edge under the titlebar so the traffic-light buttons
        // sit on top of the sidebar's vibrant material:
        //   1. `.fullSizeContentView` — let content reach under titlebar.
        //   2. `titlebarAppearsTransparent` + `titleVisibility = .hidden`
        //      — no opaque strip / title text on top of the sidebar.
        //   3. An `NSToolbar` containing the system-provided
        //      `.sidebarTrackingSeparator`. THIS is the load-bearing
        //      piece: without an NSToolbar carrying that separator,
        //      `NavigationSplitView`'s sidebar renders as an inset
        //      rounded panel instead of a true source-list sidebar.
        //      Same trick as `MainWindowController.installToolbar`.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Settings")
        window.toolbarStyle = .unified
        // Owned by the controller; survives close → reopen.
        window.isReleasedWhenClosed = false
        // Opt out of Cocoa state restoration so the OS cannot bring
        // this window back at the next launch.
        window.isRestorable = false
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        shouldCascadeWindows = false
        if UserDefaults.standard.string(forKey: "NSWindow Frame SettingsWindow") == nil {
            window.center()
        }
        installToolbar()
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "ccterm.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.sidebarTrackingSeparator` is system-synthesised; never
        // routed through `itemForItemIdentifier`.
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

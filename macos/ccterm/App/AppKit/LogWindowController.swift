import AppKit
import SwiftUI

/// AppKit-rooted window controller for the Logs panel. Replaces the
/// previous `Window("Logs", id: "logs")` SwiftUI scene which, after
/// #219 removed the leading `Settings { … }` scene, became the first
/// `Window` scene in `CCTermApp.body` and was therefore auto-opened
/// by SwiftUI alongside the AppKit-rooted main window on every cold
/// start. Same mitigation as `SettingsWindowController`: the contents
/// stay pure SwiftUI — `LogWindowView` is hosted via
/// `NSHostingController` — but the NSWindow lifecycle is owned by us,
/// lazy-created on the first `showWindow(_:)`, `isRestorable = false`,
/// ⌘⇧L routed through `AppCommands` → `AppDelegate.showLogsWindow()`.
@MainActor
final class LogWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: LogWindowView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Logs")
        // Owned by the controller; survives close → reopen.
        window.isReleasedWhenClosed = false
        // Opt out of Cocoa state restoration so the OS cannot bring
        // this window back at the next launch.
        window.isRestorable = false
        window.setContentSize(NSSize(width: 900, height: 500))
        window.setFrameAutosaveName("LogsWindow")
        super.init(window: window)
        shouldCascadeWindows = false
        if UserDefaults.standard.string(forKey: "NSWindow Frame LogsWindow") == nil {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

import AppKit
import SwiftUI

/// AppKit-rooted window controller for the About panel. Replaces the
/// previous `Window("About ccterm", id: "about")` SwiftUI scene which,
/// after the Logs migration, became the only `Window` scene in
/// `CCTermApp.body` and was therefore auto-opened by SwiftUI alongside
/// the AppKit-rooted main window on every cold start. Same mitigation
/// as `SettingsWindowController` / `LogWindowController`: the contents
/// stay pure SwiftUI — `AboutView` is hosted via `NSHostingController`
/// — but the NSWindow lifecycle is owned by us, lazy-created on the
/// first `showWindow(_:)`, `isRestorable = false`, App > About ccterm
/// routed through `AppCommands` → `AppDelegate.showAboutWindow()`.
///
/// Replicates the SwiftUI scene's `.windowStyle(.hiddenTitleBar)` +
/// `.windowResizability(.contentSize)` decoration: full-size content
/// view, transparent / hidden title bar, no `.resizable` bit so the
/// window snaps to `AboutView`'s intrinsic size.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "About ccterm")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        shouldCascadeWindows = false
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

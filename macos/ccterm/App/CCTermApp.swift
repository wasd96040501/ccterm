import SwiftUI

/// Every window (main, Settings, About) is AppKit-rooted and owned by
/// `AppDelegate`, lazy and `isRestorable = false`: a SwiftUI `Window` scene
/// in the leading slot auto-opens at launch and gets state-restored.
///
/// `App.body` still requires a `some Scene`, so it declares a
/// `Settings { EmptyView() }` placeholder — the one built-in scene type that
/// does not auto-open at launch — and attaches `AppCommands` to it. ⌘, is
/// replaced to route to the AppKit Settings window, so users never reach the
/// placeholder.
@main
struct CCTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            AppCommands(
                openSettings: { appDelegate.showSettingsWindow() },
                openAbout: { appDelegate.showAboutWindow() },
                newSession: { appDelegate.newSession() }
            )
        }
    }
}

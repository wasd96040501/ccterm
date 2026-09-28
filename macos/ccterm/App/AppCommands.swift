import AppKit
import SwiftUI

/// The app's menu commands, attached to `CCTermApp`'s placeholder scene.
/// SwiftUI installs them as `NSMenuItem`s on the main menu; ⌘, and
/// App > About ccterm call into `AppDelegate`, and everything else is a nil-
/// targeted action the key window's responder chain answers.
struct AppCommands: Commands {
    let openSettings: @MainActor () -> Void
    let openAbout: @MainActor () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ccterm") {
                openAbout()
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        // Xcode's pair: ⌘W closes a tab, ⇧⌘W the window. A window without
        // tabs answers no `closeTab:`, so ⌘W closes it.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if !NSApp.sendAction(Selector(("closeTab:")), to: nil, from: nil) {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}

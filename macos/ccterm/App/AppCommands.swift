import AppKit
import SwiftUI

/// The app's menu commands, attached to `CCTermApp`'s placeholder scene.
/// SwiftUI installs them as `NSMenuItem`s on the main menu; ⌘,, App > About
/// ccterm and File > New Tab call into `AppDelegate`, and everything
/// else is a nil-targeted action the key window's responder chain answers.
struct AppCommands: Commands {
    let openSettings: @MainActor () -> Void
    let openAbout: @MainActor () -> Void
    let newTab: @MainActor () -> Void

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
        // A nil-targeted `newTab:`, so the key window's editor area answers —
        // with the focus in a tab or in the sidebar; with no main window, or
        // another window key, it falls to `AppDelegate`, which shows the main
        // window first.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                if !NSApp.sendAction(Selector(("newTab:")), to: nil, from: nil) {
                    newTab()
                }
            }
            .keyboardShortcut("t", modifiers: .command)
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
            // ⌘. stops the active session tab's turn, from wherever the focus is.
            Button("Stop") {
                NSApp.sendAction(Selector(("stopResponding:")), to: nil, from: nil)
            }
            .keyboardShortcut(".", modifiers: .command)
        }
    }
}

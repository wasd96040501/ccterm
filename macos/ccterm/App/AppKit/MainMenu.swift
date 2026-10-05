import AppKit
import TranscriptWorkspace

/// The app's main menu, as AppKit's own app template lays it out. Every item
/// but the app's standard ones sends its action to nil: the key window's
/// responder chain answers it — the editor area, the session tab, the New
/// view, the text in focus — and AppKit enables an item only while something
/// in the chain does (`validateMenuItem(_:)` where that depends on state).
/// `AppDelegate`, at the chain's end, answers what no window does: About,
/// Settings, a New Tab with no main window key, ⌘W in a window without tabs.
///
/// Its words are in the `MainMenu` table: a menu's words, apart from the
/// app's other strings of the same English ("Window").
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        let services = NSMenu()
        let windows = menu(
            String(localized: "Window", table: "MainMenu"),
            [
                item(String(localized: "Minimize", table: "MainMenu"), #selector(NSWindow.performMiniaturize(_:)), "m"),
                item(String(localized: "Zoom", table: "MainMenu"), #selector(NSWindow.performZoom(_:))),
                .separator(),
                item(
                    String(localized: "Bring All to Front", table: "MainMenu"),
                    #selector(NSApplication.arrangeInFront(_:))),
            ])
        let help = menu(
            String(localized: "Help", table: "MainMenu"),
            [
                item(String(localized: "ccterm Help", table: "MainMenu"), #selector(NSApplication.showHelp(_:)), "?")
            ])
        for submenu in [
            menu(
                "ccterm",
                [
                    item(
                        String(localized: "About ccterm", table: "MainMenu"), #selector(AppDelegate.showAboutWindow(_:))
                    ),
                    .separator(),
                    item(
                        String(localized: "Settings…", table: "MainMenu"),
                        #selector(AppDelegate.showSettingsWindow(_:)), ","),
                    .separator(),
                    {
                        let item = NSMenuItem(
                            title: String(localized: "Services", table: "MainMenu"), action: nil, keyEquivalent: "")
                        item.submenu = services
                        return item
                    }(),
                    .separator(),
                    item(String(localized: "Hide ccterm", table: "MainMenu"), #selector(NSApplication.hide(_:)), "h"),
                    item(
                        String(localized: "Hide Others", table: "MainMenu"),
                        #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                    item(
                        String(localized: "Show All", table: "MainMenu"),
                        #selector(NSApplication.unhideAllApplications(_:))),
                    .separator(),
                    item(
                        String(localized: "Quit ccterm", table: "MainMenu"), #selector(NSApplication.terminate(_:)), "q"
                    ),
                ]),
            menu(
                String(localized: "File", table: "MainMenu"),
                [
                    item(
                        String(localized: "New Tab", table: "MainMenu"), #selector(EditorAreaViewController.newTab(_:)),
                        "t"),
                    item(String(localized: "Choose Folder…", table: "MainMenu"), Selector(("chooseFolder:")), "o"),
                    .separator(),
                    // Xcode's pair: ⌘W a tab — or the window, where it has none — ⇧⌘W the window.
                    item(
                        String(localized: "Close Tab", table: "MainMenu"),
                        #selector(EditorAreaViewController.closeTab(_:)), "w"),
                    item(
                        String(localized: "Close Window", table: "MainMenu"), #selector(NSWindow.performClose(_:)), "w",
                        [.command, .shift]),
                    .separator(),
                    item(String(localized: "Stop", table: "MainMenu"), TranscriptTab.stopAction, "."),
                ]),
            menu(
                String(localized: "Edit", table: "MainMenu"),
                [
                    item(String(localized: "Undo", table: "MainMenu"), Selector(("undo:")), "z"),
                    item(String(localized: "Redo", table: "MainMenu"), Selector(("redo:")), "z", [.command, .shift]),
                    .separator(),
                    item(String(localized: "Cut", table: "MainMenu"), #selector(NSText.cut(_:)), "x"),
                    item(String(localized: "Copy", table: "MainMenu"), #selector(NSText.copy(_:)), "c"),
                    item(String(localized: "Paste", table: "MainMenu"), #selector(NSText.paste(_:)), "v"),
                    item(
                        String(localized: "Paste and Match Style", table: "MainMenu"),
                        #selector(NSTextView.pasteAsPlainText(_:)), "v",
                        [.command, .option, .shift]),
                    item(String(localized: "Delete", table: "MainMenu"), #selector(NSText.delete(_:))),
                    item(String(localized: "Select All", table: "MainMenu"), #selector(NSText.selectAll(_:)), "a"),
                ]),
            menu(
                String(localized: "View", table: "MainMenu"),
                [
                    item(
                        String(localized: "Enter Full Screen", table: "MainMenu"),
                        #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
                ]),
            windows,
            help,
        ] {
            let holder = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            main.addItem(holder)
        }
        NSApp.servicesMenu = services
        NSApp.windowsMenu = windows
        NSApp.helpMenu = help
        return main
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.items = items
        return menu
    }

    /// An item sending `action` to nil.
    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

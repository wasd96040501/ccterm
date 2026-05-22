import AppKit
import SwiftUI

/// Builds the application's main `NSMenu` and installs it on `NSApp`.
/// Called from `AppDelegate.applicationDidFinishLaunching`; replaces
/// the SwiftUI `Commands` DSL the old `AppCommands` used.
@MainActor
enum AppKitMenuBuilder {
    static func install(searchBus: TranscriptSearchBus) {
        let mainMenu = NSMenu(title: "MainMenu")

        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeFindMenu(searchBus: searchBus))
        mainMenu.addItem(makeViewMenu())
        mainMenu.addItem(makeWindowMenu())
        #if DEBUG
        mainMenu.addItem(makeDebugMenu())
        #endif
        mainMenu.addItem(makeHelpMenu())

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menus

    private static func makeAppMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "ccterm", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "ccterm")

        let about = NSMenuItem(
            title: String(localized: "About ccterm"),
            action: #selector(AppMenuActions.openAbout(_:)),
            keyEquivalent: "")
        about.target = AppMenuActions.shared
        menu.addItem(about)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(AppMenuActions.openSettings(_:)),
            keyEquivalent: ",")
        settings.target = AppMenuActions.shared
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(makeHide())
        menu.addItem(makeHideOthers())
        menu.addItem(makeShowAll())
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit ccterm"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)

        parent.submenu = menu
        return parent
    }

    private static func makeFileMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "File"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "File"))
        let close = NSMenuItem(
            title: String(localized: "Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        menu.addItem(close)
        parent.submenu = menu
        return parent
    }

    private static func makeEditMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "Edit"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(makeStandard(title: "Undo", action: Selector(("undo:")), key: "z"))
        let redo = makeStandard(title: "Redo", action: Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(makeStandard(title: "Cut", action: #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(makeStandard(title: "Copy", action: #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(makeStandard(title: "Paste", action: #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(
            makeStandard(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a")
        )
        parent.submenu = menu
        return parent
    }

    private static func makeFindMenu(searchBus: TranscriptSearchBus) -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "Find"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "Find"))
        let find = NSMenuItem(
            title: String(localized: "Find in Transcript"),
            action: #selector(AppMenuActions.findInTranscript(_:)),
            keyEquivalent: "f")
        find.target = AppMenuActions.shared
        AppMenuActions.shared.searchBus = searchBus
        menu.addItem(find)
        parent.submenu = menu
        return parent
    }

    private static func makeViewMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "View"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "View"))
        let enter = NSMenuItem(
            title: String(localized: "Enter Full Screen"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        enter.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(enter)
        parent.submenu = menu
        return parent
    }

    private static func makeWindowMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "Window"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(
            makeStandard(
                title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                key: "m"))
        menu.addItem(makeStandard(title: "Zoom", action: #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(
            makeStandard(
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:))))
        parent.submenu = menu
        NSApp.windowsMenu = menu
        return parent
    }

    #if DEBUG
    private static func makeDebugMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Debug")
        let logs = NSMenuItem(
            title: "Logs", action: #selector(AppMenuActions.openLogs(_:)), keyEquivalent: "L")
        logs.keyEquivalentModifierMask = [.command, .shift]
        logs.target = AppMenuActions.shared
        menu.addItem(logs)
        parent.submenu = menu
        return parent
    }
    #endif

    private static func makeHelpMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "Help"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: String(localized: "Help"))
        parent.submenu = menu
        NSApp.helpMenu = menu
        return parent
    }

    // MARK: - Convenience

    private static func makeStandard(
        title: String, action: Selector, key: String = ""
    ) -> NSMenuItem {
        NSMenuItem(title: String(localized: String.LocalizationValue(title)), action: action, keyEquivalent: key)
    }

    private static func makeHide() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "Hide ccterm"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        return item
    }
    private static func makeHideOthers() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        item.keyEquivalentModifierMask = [.command, .option]
        return item
    }
    private static func makeShowAll() -> NSMenuItem {
        NSMenuItem(
            title: String(localized: "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
    }
}

/// Holds the `@objc` selector targets for menu actions that need a
/// retained instance (so the menu items can route to them via
/// `target = AppMenuActions.shared`). Singleton scope is fine — the
/// app has exactly one main menu.
@MainActor
final class AppMenuActions: NSObject {
    static let shared = AppMenuActions()
    weak var searchBus: TranscriptSearchBus?

    @objc func openAbout(_ sender: Any?) {
        OpenWindowBridge.shared.open("about")
    }

    @objc func openSettings(_ sender: Any?) {
        OpenWindowBridge.shared.open("settings")
    }

    @objc func openLogs(_ sender: Any?) {
        OpenWindowBridge.shared.open("logs")
    }

    @objc func findInTranscript(_ sender: Any?) {
        searchBus?.requestFocus()
    }
}

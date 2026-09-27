import AppKit

/// An editor-area window of transcripts — tabs, two editors side by side, a find
/// bar in each — over the documents in `DemoMessage.script`. Run with
/// `make demo-kit`.
///
/// What it is for: the things a probe can't tell you. Read the documents and check
/// that they look like documents — the only test markdown rendering really has.
/// Drag the divider and the window edge across the content-width clamp. Use the
/// tools at the bottom to mutate rows above the viewport and watch that the text
/// under your eyes doesn't move. Drag tabs between editors, pin one, find in each.
@main
struct Demo {

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Held by this scope, which outlives the app.
        let windowController = DemoWindowController()
        app.mainMenu = makeMainMenu()
        windowController.showWindow(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    /// Every item has a `nil` target, so it dispatches down the responder chain,
    /// which ends at the window controller.
    ///
    /// The Edit menu is not decoration: it is the **only** thing that makes ⌘C
    /// work. A key equivalent is not delivered to the first responder the way a
    /// keystroke is — `NSApplication` hands it to the main menu, and the Copy item,
    /// carrying `copy:` and no target, is what turns it into a chain dispatch that
    /// reaches the selected row. An app with a normal Edit menu gets ⌘C for free.
    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit \(ProcessInfo.processInfo.processName)",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "New Tab", action: #selector(DemoWindowController.newTab(_:)),
            keyEquivalent: "t")
        fileMenu.addItem(
            withTitle: "Close Tab", action: #selector(DemoWindowController.closeTab(_:)),
            keyEquivalent: "w")
        main.addItem(submenu: fileMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(.separator())
        // AppKit's own wiring for a find: the action as the item's tag.
        for (title, key, action) in [
            ("Find…", "f", NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .nextMatch),
            ("Find Previous", "G", .previousMatch),
        ] {
            let item = editMenu.addItem(
                withTitle: title, action: #selector(DemoWindowController.performFindAction(_:)),
                keyEquivalent: key)
            item.tag = action.rawValue
        }
        main.addItem(submenu: editMenu)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            withTitle: "Hide Tools", action: #selector(DemoWindowController.toggleTools(_:)),
            keyEquivalent: "t"
        ).keyEquivalentModifierMask = [.command, .option]
        main.addItem(submenu: viewMenu)

        // Xcode's bindings for the same commands.
        let navigateMenu = NSMenu(title: "Navigate")
        navigateMenu.addItem(
            withTitle: "Show Next Tab", action: #selector(DemoWindowController.showNextTab(_:)),
            keyEquivalent: "}")
        navigateMenu.addItem(
            withTitle: "Show Previous Tab",
            action: #selector(DemoWindowController.showPreviousTab(_:)), keyEquivalent: "{")
        navigateMenu.addItem(.separator())
        navigateMenu.addItem(
            withTitle: "Pin Tab", action: #selector(DemoWindowController.togglePinnedTab(_:)),
            keyEquivalent: "")
        navigateMenu.addItem(.separator())
        navigateMenu.addItem(
            withTitle: "Add Editor on Right",
            action: #selector(DemoWindowController.addEditorOnRight(_:)), keyEquivalent: "t"
        ).keyEquivalentModifierMask = [.command, .control]
        navigateMenu.addItem(
            withTitle: "Close Editor", action: #selector(DemoWindowController.closeEditor(_:)),
            keyEquivalent: "w"
        ).keyEquivalentModifierMask = [.command, .control, .shift]
        main.addItem(submenu: navigateMenu)

        return main
    }
}

extension NSMenu {

    fileprivate func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}

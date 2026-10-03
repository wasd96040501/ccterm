import AppKit

/// The style page: every component of `Components` tiled on one page, live, with
/// fixture models — the design sheet's parts, built from the components the
/// app uses. Run with `make design`.
@main
struct Design {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // `NSApplication.delegate` is weak; this scope outlives the app.
        let appDelegate = DesignAppDelegate()
        app.delegate = appDelegate
        app.run()
    }

    /// The page's sections, in order: one per component family.
    static func sections() -> [DesignPageViewController.Section] {
        [FormSpecimen.section(), AccountsSpecimen.section(), SidebarSpecimen.section()]
    }

    /// Quit, and an Edit menu: without it ⌘C, ⌘V and ⌘A never reach a field
    /// (a key equivalent goes to the main menu, not the first responder).
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit \(ProcessInfo.processInfo.processName)",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for submenu in [appMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}

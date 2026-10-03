import AppKit

/// Builds the menu and the page's window once the app has launched (inside the
/// run loop, so its autorelease pools drain), and quits when the window closes.
final class DesignAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: DesignWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Design.makeMainMenu()
        let windowController = DesignWindowController()
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

import AppKit

/// The demo's composition root: one window, and quitting when it closes.
@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: DemoWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DemoWindowController()
        windowController = controller
        controller.showWindow(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

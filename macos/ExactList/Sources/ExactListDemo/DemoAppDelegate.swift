import AppKit

/// The demo's composition root: one window, and quitting when it closes.
@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: DemoWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        fatalError("unimplemented: demo")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

import AppKit

/// The demo's composition root: builds the menu and the window once the app has
/// launched, and quits when that window closes.
///
/// **Built here and not in `main()`, and the difference is memory.** `main()`
/// runs before `NSApplication.run()`, outside any autorelease pool the run loop
/// drains — so anything autoreleased while the window was being built went into
/// the thread's top-level pool, which lives as long as the process. That was the
/// window's first two tabs: close one after loading ten thousand rows into it and
/// its view controller, its transcript and everything typeset in it stayed
/// resident, where a tab opened later with ⌘T was freed. Measured with a
/// memgraph, not inferred — the only thing holding the closed editor was an
/// `@autoreleasepool` page. Here, inside the run loop, the pools drain as usual.
@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: DemoWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Demo.makeMainMenu()
        let windowController = DemoWindowController()
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The demo is its one window: closing it quits, as `CLAUDE.md` §5 says it
    /// does. Without this `NSApplication` keeps running with nothing on screen,
    /// which is its default for an app that could open another.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

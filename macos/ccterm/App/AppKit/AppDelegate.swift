import AgentSDK
import AppKit
import SwiftUI

/// AppKit-side application delegate and the app's composition root. Owns
/// the main window's lifecycle — creating it from
/// `applicationDidFinishLaunching` instead of declaring a SwiftUI `Window`
/// scene — and every auxiliary window's (lazy `SettingsWindowController` /
/// `AboutWindowController`), so the OS can't resurface them from saved
/// state at the next launch and SwiftUI can't auto-open them as the
/// leading `Window` scene.
///
/// `CCTermApp.body` keeps only a `Settings { EmptyView() }` placeholder to
/// satisfy the `App` protocol's `some Scene` requirement; menu items live
/// in `AppCommands` — a SwiftUI `Commands` block attached to that
/// placeholder scene. SwiftUI merges those into the app's main menu, so
/// cold-start menu clicks (⌘, → `showSettingsWindow()`, App > About ccterm
/// → `showAboutWindow()`) resolve their closures without an AppKit bridge.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?

    /// Every transcript on disk, for the main window's sidebar. Process-wide:
    /// it mirrors a directory the CLI owns, and one scan serves every window.
    private var library: LibraryStore?

    /// Lazy AppKit-rooted Settings window. Created on the first
    /// `showSettingsWindow()` call (⌘, or App > Settings… menu item)
    /// — never at launch, so the OS cannot resurface it from saved
    /// state.
    private var settingsWindowController: SettingsWindowController?

    func showSettingsWindow() {
        let controller =
            settingsWindowController
            ?? {
                let c = SettingsWindowController()
                settingsWindowController = c
                return c
            }()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Lazy AppKit-rooted About window. Same shape as
    /// `settingsWindowController` — created
    /// on the first `showAboutWindow()` call (App > About ccterm menu
    /// item) so SwiftUI cannot auto-open it as the leading `Window`
    /// scene and the OS cannot resurface it from saved state.
    private var aboutWindowController: AboutWindowController?

    func showAboutWindow() {
        let controller =
            aboutWindowController
            ?? {
                let c = AboutWindowController()
                aboutWindowController = c
                return c
            }()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isUnderXCTest { return }

        // The index only saves reading: Caches, which the system may clear.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.ccterm.app", isDirectory: true)
        var directories = [SessionDirectory(environment: ProcessInfo.processInfo.environment)]
        #if DEBUG
            // A made-up session showing every kind of row, in a directory of
            // its own under the temporary directory.
            do {
                directories.append(SessionDirectory(url: try SampleSession.install()))
            } catch {
                appLog(.warning, "AppDelegate", "sample session not written: \(error.localizedDescription)")
            }
        #endif
        let library = LibraryStore(
            directories: directories, indexURL: caches.appendingPathComponent("LibraryIndex.plist"))
        self.library = library
        let controller = MainWindowController(library: library)
        // Where the frame persists is the app's configuration, not the window's:
        // a `MainWindowController` built anywhere else writes no defaults.
        controller.windowFrameAutosaveName = "MainWindow"
        mainWindowController = controller
        library.start()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Mirrors `CCTermApp.isUnderXCTest`. The test path installs the
    /// `NSWindow` swizzles in `CCTermApp.init` and we must skip
    /// creating the real window here so XCTest doesn't see a stray
    /// visible window.
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

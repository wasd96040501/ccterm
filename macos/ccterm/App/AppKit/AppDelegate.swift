import AppKit
import SwiftUI

/// AppKit-side application delegate. Owns the main window's lifecycle
/// — creating it from `applicationDidFinishLaunching` instead of
/// declaring a SwiftUI `Window` scene — so the transcript's mount and
/// frame-change handlers run in the source phase, decoupled from
/// SwiftUI's commit pass. Also owns every auxiliary window's
/// lifecycle (lazy `SettingsWindowController` /
/// `AboutWindowController`) so the OS can't resurface them from
/// saved state at the next launch and SwiftUI can't auto-open them
/// as the leading `Window` scene.
///
/// `CCTermApp.body` keeps only a `Settings { EmptyView() }` placeholder
/// to satisfy the `App` protocol's `some Scene` requirement; menu
/// items + the ⌘F bus hook for transcript search live in `AppCommands`
/// — a SwiftUI `Commands` block attached to that placeholder scene.
/// SwiftUI merges those into the app's main menu, so cold-start menu
/// clicks (⌘, → `showSettingsWindow()`, App > About ccterm →
/// `showAboutWindow()`) resolve their closures without needing an
/// AppKit bridge.
///
/// The delegate also owns the app-scope state (`AppState`,
/// `TranscriptSearchBus`). Previously these were `@State` on
/// `CCTermApp`; now that the main window is AppKit-rooted, AppKit is
/// the right owner — SwiftUI scenes that need them read them via
/// `appDelegate.appState.…`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let searchBus = TranscriptSearchBus()

    private(set) var mainWindowController: MainWindowController?
    let selectionModel = MainSelectionModel()

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

        let controller = MainWindowController(
            model: selectionModel, appState: appState, searchBus: searchBus)
        mainWindowController = controller
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

    /// Before NSApplication tears down the process, give every active
    /// CLI subprocess a chance to flush its session file. The shutdown
    /// runs sessions in parallel inside
    /// `SessionManager.shutdownAllAsync()`, so wall time is bounded by
    /// the slowest CLI (the AgentSDK enforces a 5s per-process graceful
    /// timeout before SIGTERM) rather than scaling linearly with the
    /// session count.
    ///
    /// Returning `.terminateLater` parks the quit; we reply once the
    /// task group finishes. Under XCTest we skip entirely — the test
    /// harness owns lifecycle and there's no real CLI to shut down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isUnderXCTest { return .terminateNow }
        appLog(.info, "AppDelegate", "applicationShouldTerminate — begin parallel CLI shutdown")
        Task { @MainActor in
            await appState.sessionManager.shutdownAllAsync()
            appLog(.info, "AppDelegate", "applicationShouldTerminate — replying")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Mirrors `CCTermApp.isUnderXCTest`. The test path installs the
    /// `NSWindow` swizzles in `CCTermApp.init` and we must skip
    /// creating the real window here so XCTest doesn't see a stray
    /// visible window.
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

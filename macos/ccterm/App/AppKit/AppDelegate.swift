import AppKit
import SwiftUI

/// AppKit-side application delegate. Owns the main window's lifecycle
/// — creating it from `applicationDidFinishLaunching` instead of
/// declaring a SwiftUI `Window` scene — so the transcript's mount and
/// frame-change handlers run in the source phase, decoupled from
/// SwiftUI's commit pass.
///
/// Auxiliary windows (Settings / Logs / About) stay as SwiftUI `Window`
/// scenes declared in `CCTermApp`; their menu items (and the ⌘F bus
/// hook for transcript search) live in `AppCommands` — a SwiftUI
/// `Commands` block attached to the Settings scene. SwiftUI merges
/// those into the app's main menu, so cold-start menu clicks resolve
/// `@Environment(\.openWindow)` correctly without needing an AppKit
/// bridge.
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

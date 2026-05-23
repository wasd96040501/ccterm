import AppKit
import SwiftUI

/// Main window AND Settings are AppKit-rooted (see `AppDelegate`,
/// `MainWindowController`, `SettingsWindowController`). The Settings
/// migration is what fixes the long-standing "Settings occasionally
/// pops up at launch" bug — a SwiftUI `Settings { … }` scene's
/// internal NSWindow was being resurfaced by OS state restoration on
/// some cold starts. Lazy AppKit construction with
/// `isRestorable = false` removes that grey area.
///
/// What stays SwiftUI here is the SCENE structure for Logs / About —
/// their menu items + ⌘F come from the SwiftUI `Commands` DSL
/// attached to the Logs scene so cold-start menu clicks (before any
/// auxiliary scene has mounted) still resolve
/// `@Environment(\.openWindow)`. The `.appSettings` command group is
/// re-installed manually in `AppCommands` so ⌘, routes to our
/// AppKit-rooted Settings window.
@main
struct CCTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Hosted unit tests inject this env var. When present we keep NSApp alive
    // (snapshot/AppKit rendering still needs it) but skip every Window scene
    // so the host app never draws a window or steals focus.
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        // Logs is the only "first scene" remaining — Settings moved
        // to AppKit-rooted `SettingsWindowController`. `.commands`
        // attaches here so the menu items are installed at the same
        // launch-phase point as before.
        Window("Logs", id: "logs") {
            LogWindowView()
        }
        .defaultSize(width: 900, height: 500)
        .commands {
            AppCommands(
                searchBus: appDelegate.searchBus,
                openSettings: { appDelegate.showSettingsWindow() }
            )
        }

        Window("About ccterm", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }

    init() {
        UserDefaults.standard.set(0, forKey: "NSInitialToolTipDelay")
        if Self.isUnderXCTest {
            // Hosted unit tests need NSApp alive (snapshot/AppKit rendering
            // depends on it), but should never display a window or steal
            // focus. Accessory policy hides the Dock icon; swizzling the
            // window-ordering selectors to no-ops prevents SwiftUI's auto-
            // opened Window scenes from ever appearing on screen — closing
            // them after the fact still produced a visible flash.
            NSApplication.shared.setActivationPolicy(.accessory)
            NSWindow.suppressOrderingForTesting()
            return
        }
        MainThreadWatchdog.start()
        // First-launch model catalog fetch — eagerly kicked off at
        // app init so the picker has data ready by the time the user
        // can interact with it. `prefetchIfNeeded` returns
        // synchronously after spawning the background fetch Task, so
        // this does not block init. Subsequent launches hit the
        // on-disk cache and short-circuit before fetching. Model
        // loading is intentionally NOT tied to session CLI bootstrap;
        // see `Session+Start.bootstrap` for the matching note.
        MainActor.assumeIsolated {
            ModelStore.shared.prefetchIfNeeded()
        }
    }
}

extension NSWindow {
    fileprivate static func suppressOrderingForTesting() {
        let pairs: [(Selector, Selector)] = [
            (
                #selector(NSWindow.makeKeyAndOrderFront(_:)),
                #selector(NSWindow._ccterm_noopMakeKeyAndOrderFront(_:))
            ),
            (
                #selector(NSWindow.orderFront(_:)),
                #selector(NSWindow._ccterm_noopOrderFront(_:))
            ),
            (
                #selector(NSWindow.orderFrontRegardless),
                #selector(NSWindow._ccterm_noopOrderFrontRegardless)
            ),
        ]
        for (original, replacement) in pairs {
            guard
                let m1 = class_getInstanceMethod(NSWindow.self, original),
                let m2 = class_getInstanceMethod(NSWindow.self, replacement)
            else { continue }
            method_exchangeImplementations(m1, m2)
        }
    }

    @objc fileprivate func _ccterm_noopMakeKeyAndOrderFront(_ sender: Any?) {}
    @objc fileprivate func _ccterm_noopOrderFront(_ sender: Any?) {}
    @objc fileprivate func _ccterm_noopOrderFrontRegardless() {}

    /// Test-only escape hatch — invokes the real `makeKeyAndOrderFront(_:)`
    /// even when `suppressOrderingForTesting()` has neutered it. Used by
    /// `ViewSnapshot` (cctermTests) to wake an off-screen snapshot window
    /// enough that SwiftUI's appearance lifecycle (`.task`, `.onAppear`)
    /// fires on the hosted view.
    ///
    /// The swizzle exchanges implementations symmetrically: under
    /// XCTest the real entry point lives at
    /// `_ccterm_noopMakeKeyAndOrderFront:`, so we route there to bypass
    /// the no-op stub. Outside XCTest there's nothing to bypass and we
    /// just forward to the public selector.
    func ccterm_orderFrontForTesting() {
        let bypass = NSSelectorFromString("_ccterm_noopMakeKeyAndOrderFront:")
        if responds(to: bypass) {
            perform(bypass, with: nil)
        } else {
            makeKeyAndOrderFront(nil)
        }
    }
}

/// SwiftUI command bar attached to the Logs scene. Survives the
/// AppKit-host migration: SwiftUI's command system installs these as
/// NSMenuItem instances on the merged main menu, so the AppKit main
/// window keeps full menu coverage without an
/// `applicationDidFinishLaunching`-side NSMenu rebuild. ⌘F focus
/// routes through `TranscriptSearchBus.requestFocus()`, which the
/// AppKit toolbar's `TranscriptSearchToolbarBridge` picks up
/// reactively via `withObservationTracking`. ⌘, routes through
/// `openSettings` into `AppDelegate.showSettingsWindow()` — the
/// AppKit-rooted Settings window — bypassing SwiftUI's `Settings`
/// scene entirely.
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let searchBus: TranscriptSearchBus
    let openSettings: @MainActor () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ccterm") {
                openWindow(id: "about")
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        // Top-level Find menu — gives ⌘F a stable AppKit responder-chain
        // route. Routed via `TranscriptSearchBus` so the per-window
        // subscriber lives behind a stable observation channel.
        CommandMenu("Find") {
            Button(action: { searchBus.requestFocus() }) {
                Text("Find in Transcript")
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Debug") {
            Button("Logs") {
                openWindow(id: "logs")
            }
            .keyboardShortcut("L", modifiers: [.command, .shift])
        }
    }
}

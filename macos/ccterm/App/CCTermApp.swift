import AppKit
import SwiftUI

@main
struct CCTermApp: App {
    @State private var appState = AppState()
    @State private var searchBus = TranscriptSearchBus()

    // Hosted unit tests inject this env var. When present we keep NSApp alive
    // (snapshot/AppKit rendering still needs it) but skip every Window scene
    // so the host app never draws a window or steals focus.
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        Window("ccterm", id: "main") {
            RootView2()
                .environment(appState.sessionManager)
                .environment(appState.recentProjects)
                .environment(appState.inputDraftStore)
                .environment(\.syntaxEngine, appState.syntaxEngine)
                .environment(searchBus)
                .environment(appState.notificationService)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 860)
        .windowResizability(.contentSize)
        .commands {
            AppCommands(searchBus: searchBus)
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 830, height: 534)
        .windowResizability(.contentSize)

        Window("Logs", id: "logs") {
            LogWindowView()
        }
        .defaultSize(width: 900, height: 500)
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
        #if DEBUG
        // Temporary: enabled so re-entry perf trace lands in os_log.
        // Filter with category == "Transcript2Perf". Revert before merging.
        Transcript2PerfLog.enabled = true
        #endif
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

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let searchBus: TranscriptSearchBus

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(action: { openWindow(id: "settings") }) {
                Label("Settings", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        // Top-level Find menu — the entry is guaranteed present in
        // the menu bar regardless of whether SwiftUI auto-installed
        // the Edit menu, and gives ⌘F a stable AppKit responder-chain
        // route (`typeKey(_:modifierFlags:)` does not reliably
        // synthesize the shortcut through window-local monitors).
        //
        // The transcript's search field is always visible in the
        // window toolbar (rendered by `.searchable` on
        // `ChatHistoryView`); ⌘F's job is purely to hand keyboard
        // focus to that field. Routed via `TranscriptSearchBus` —
        // an `@Observable` counter — instead of `NotificationCenter`,
        // because the per-view subscriber lives behind a SwiftUI
        // `.id(sessionId)` boundary.
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

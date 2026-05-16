import AppKit
import SwiftUI

struct CCTermApp: App {
    @State private var appState = AppState()
    @State private var searchBus = TranscriptSearchBus()

    var body: some Scene {
        Window("ccterm", id: "main") {
            RootView2()
                .environment(appState.sessionManager2)
                .environment(\.syntaxEngine, appState.syntaxEngine)
                .environment(searchBus)
                // `.windowStyle(.hiddenTitleBar)` alone hides the title
                // text but does NOT insert `.fullSizeContentView` into
                // the underlying `NSWindow.styleMask` — the content
                // still starts below the title-bar band. `WindowConfigurator`
                // captures the window reference after layout and flips
                // the flag so the SwiftUI content view extends up under
                // the chrome. Verified by
                // `ChatHistoryTopFadeScrimUITests.testTranscriptFlushToWindowTop`.
                .background(WindowConfigurator())
        }
        // `.hiddenTitleBar` enables `NSWindow.StyleMask.fullSizeContentView`
        // so the content view extends up under the chrome. Pairing it with
        // `.unifiedCompact` collapses the toolbar into the title-bar band
        // (instead of stacking below it as the default `.expanded` style
        // does) — that's what lets `.searchable` host a search field at
        // the top of the window without pushing the transcript ~52pt down.
        // `ChatHistoryView` adds `.toolbarBackground(.hidden, for: .windowToolbar)`
        // so the toolbar's material doesn't paint over the transcript.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
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
        CursorGuard.install()
        MainThreadWatchdog.start()
    }
}

/// Tiny `NSViewRepresentable` whose only job is to flip the underlying
/// `NSWindow.styleMask` flags that SwiftUI's `.windowStyle(.hiddenTitleBar)`
/// leaves off. Specifically:
///
/// - `.fullSizeContentView` — makes the content view occupy the full
///   window including the title-bar band, so SwiftUI views with
///   `.ignoresSafeArea(edges: .top)` actually render up to the
///   window's top edge.
/// - `titlebarAppearsTransparent = true` — pairs with the flag above
///   so the title-bar area doesn't paint its own opaque background
///   over the content.
///
/// `view.window` is `nil` while `makeNSView` runs (the view is added
/// to the hierarchy after `makeNSView` returns), so the configuration
/// is deferred to the next runloop tick. Idempotent — the same flags
/// can be set on every layout pass without side effects.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { [weak probe] in
            guard let window = probe?.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
        }
        return probe
    }

    func updateNSView(_: NSView, context _: Context) {}
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

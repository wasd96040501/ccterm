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
        CursorGuard.install()
        MainThreadWatchdog.start()
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
        // the Edit menu, and XCUITests can click it by name in lieu
        // of relying on `⌘F` event delivery (XCUITest's
        // `typeKey(_:modifierFlags:)` doesn't reliably route through
        // the menu shortcut path).
        //
        // Routes through `TranscriptSearchBus` — an `@Observable`
        // counter — instead of `NotificationCenter`. The per-view
        // `.onChange(of:)` subscriber is the SwiftUI-native path and
        // delivers reliably across the `.id(sessionId)` boundary on
        // `ChatHistoryView`.
        CommandMenu("Find") {
            Button(action: { searchBus.requestOpen() }) {
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

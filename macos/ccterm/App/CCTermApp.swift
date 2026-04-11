import SwiftUI

@main
struct CCTermApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("ccterm", id: "main") {
            RootView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 860)
        .windowResizability(.contentSize)
        .commands {
            AppCommands(appState: appState)
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
        CLICapabilityStore.shared.detectVersion()
        CLICapabilityStore.shared.loadFromCache()
        ModelStore.prefetchIfNeeded()
        DispatchQueue.main.async { _ = NSOpenPanel() }

        #if DEBUG
        appLog(.info, "App", "ccterm launched — debug build")
        appLog(.debug, "App", "Tooltip delay reset, CursorGuard installed")
        appLog(.info, "CLICapabilityStore", "CLI version detected, cache loaded")
        appLog(.info, "ModelStore", "Prefetching model list")
        appLog(.warning, "SessionService", "No previous session found, starting fresh")
        appLog(.error, "WebViewBridge", "Failed to load bridge.js — file not found (sample)")
        appLog(.debug, "App", "NSOpenPanel warm-up scheduled")
        #endif
    }
}

struct AppCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(action: { openWindow(id: "settings") }) {
                Label("Settings", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { appState.startNewConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(before: .windowArrangement) {
            Button("Logs") {
                openWindow(id: "logs")
            }
            .keyboardShortcut("L", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find") { appState.searchFocusTrigger = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { appState.findNext() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { appState.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

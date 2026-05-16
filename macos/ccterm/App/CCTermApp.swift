import SwiftUI

struct CCTermApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("ccterm", id: "main") {
            RootView2()
                .environment(appState.sessionManager2)
                .environment(\.syntaxEngine, appState.syntaxEngine)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 860)
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
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

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(action: { openWindow(id: "settings") }) {
                Label("Settings", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        // Real menu item drives the ⌘F shortcut. SwiftUI's
        // `keyboardShortcut` on a hidden Button + NSEvent local
        // monitors both have been observed to not deliver in
        // XCUITest harnesses; a menu-attached shortcut routes
        // through the standard AppKit responder chain and is
        // queryable by the test runner. `ChatHistoryView`
        // subscribes via `NotificationCenter` (see `findInTranscript`).
        CommandGroup(after: .textEditing) {
            Button(action: {
                NotificationCenter.default.post(
                    name: .findInTranscript, object: nil)
            }) {
                Text("Find in transcript")
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

extension Notification.Name {
    /// Posted by the global ⌘F menu item; consumed by the active
    /// `ChatHistoryView` to toggle its in-transcript search bar.
    /// Decoupled this way because the menu lives on the `App` scene
    /// (one per process) while the search bar's state lives on
    /// `ChatHistoryView` (one per session — `.id(sessionId)`-rebuilt).
    /// `NotificationCenter` is the well-trodden bridge for app-scope
    /// commands to per-view state without inventing a global
    /// `@Observable` for one boolean.
    static let findInTranscript = Notification.Name("ccterm.findInTranscript")
}

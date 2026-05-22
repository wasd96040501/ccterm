import AppKit
import SwiftUI

/// Bridge that lets AppKit-side code (e.g. an `NSMenuItem` action in
/// `AppDelegate`) open a SwiftUI `Window` scene by its `id`.
///
/// Once the main window is rooted in AppKit, the menu items that open
/// Settings / Logs / About need a way to dispatch into the SwiftUI
/// scene system without holding an `@Environment(\.openWindow)` of
/// their own. SwiftUI's `OpenWindowAction` is only resolvable from
/// inside a `View`, so each remaining SwiftUI scene installs its
/// `openWindow` env value here on first appearance via
/// `OpenWindowBridgeInstaller`. The bridge then forwards
/// `OpenWindowBridge.shared.open(id:)` calls to the captured action.
///
/// **Cold-start fallback.** Before any SwiftUI scene has mounted, the
/// captured action is `nil`. The fallback walks `NSApp.windows` for an
/// existing window whose identifier matches the requested id and
/// orders it front. SwiftUI registers an NSWindow per `Window` scene
/// on the first `openWindow(id:)` call; once the user has opened a
/// scene once, the bridge can re-front it even after the SwiftUI
/// installer has gone away.
@MainActor
@Observable
final class OpenWindowBridge {
    static let shared = OpenWindowBridge()

    @ObservationIgnored
    private var registeredAction: ((String) -> Void)?

    private init() {}

    /// Called from a SwiftUI installer (`OpenWindowBridgeInstaller`)
    /// once it has resolved `@Environment(\.openWindow)`. Subsequent
    /// calls overwrite — the most recently mounted SwiftUI scene wins.
    func register(_ action: @escaping (String) -> Void) {
        registeredAction = action
    }

    /// Open or focus the SwiftUI `Window` scene with the given id.
    /// Idempotent — opening an already-open scene re-fronts it.
    func open(_ id: String) {
        if let action = registeredAction {
            action(id)
            return
        }
        // Cold-start fallback: a SwiftUI scene hasn't installed the
        // openWindow action yet. Walk NSApp.windows for an existing
        // window whose identifier matches; if found, order it front.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == id }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        appLog(
            .warning, "OpenWindowBridge",
            "open(\(id)) called before any SwiftUI scene mounted; nothing to dispatch to")
    }
}

/// Mounts `@Environment(\.openWindow)` into `OpenWindowBridge.shared`
/// so AppKit menu items can drive SwiftUI's `Window` scenes. Attach
/// to every remaining SwiftUI scene's root view (Settings / Logs /
/// About) — first-mount wins for cold start, subsequent mounts
/// overwrite with the freshest action.
struct OpenWindowBridgeInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            OpenWindowBridge.shared.register { id in
                openWindow(id: id)
            }
        }
    }
}

extension View {
    /// Convenience: attach the openWindow bridge installer.
    func installOpenWindowBridge() -> some View {
        modifier(OpenWindowBridgeInstaller())
    }
}

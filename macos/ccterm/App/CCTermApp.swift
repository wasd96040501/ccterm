import AppKit
import SwiftUI

/// Main window is rooted in AppKit (see `AppDelegate` /
/// `MainWindowController`). The remaining SwiftUI `Window` scenes
/// declared below are auxiliary: Settings, Logs, About. They install
/// `OpenWindowBridge` so the AppKit-side menu items in
/// `AppKitMenuBuilder` can drive `openWindow(id:)`.
@main
struct CCTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Hosted unit tests inject this env var. When present we keep NSApp alive
    // (snapshot/AppKit rendering still needs it) but skip every Window scene
    // so the host app never draws a window or steals focus.
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        Window("Settings", id: "settings") {
            SettingsView()
                .installOpenWindowBridge()
        }
        .defaultSize(width: 830, height: 534)
        .windowResizability(.contentSize)

        Window("Logs", id: "logs") {
            LogWindowView()
                .installOpenWindowBridge()
        }
        .defaultSize(width: 900, height: 500)

        Window("About ccterm", id: "about") {
            AboutView()
                .installOpenWindowBridge()
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
        #if DEBUG
        // Temporary: aggregate session-switch perf counters and emit one
        // summary line per attach (category == "Transcript2Reentry").
        // Hot-path call sites push counters in-memory only — no os_log
        // per event. Revert before merging.
        Transcript2ReentryStats.enabled = true
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

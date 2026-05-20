import AppKit
import Observation

/// Tracks whether the app is the frontmost application (any window of
/// ours holds key/main focus). Posted to `@Observable` so views and
/// services can read `isAppActive` directly.
///
/// CCTerm is single-window, so app-level activation is the right grain:
/// `NSWindow.didBecomeKey/didResignKey` fires for transient panels (the
/// open-file panel, the settings window) which should not be treated as
/// "the user is away." `NSApplication.didBecomeActive/didResignActive`
/// only flips when the whole app loses or regains focus.
@Observable
@MainActor
final class AppActivationTracker {

    /// True when the app is the frontmost application. Initialized from
    /// `NSApp.isActive` so a tracker created mid-launch reflects the
    /// current state rather than a hard-coded default.
    private(set) var isAppActive: Bool

    init() {
        self.isAppActive = NSApp?.isActive ?? true
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAppActive = true }
        }
        center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAppActive = false }
        }
    }

    nonisolated deinit {}
}

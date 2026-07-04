import AppKit

/// Placeholder Settings window — a standalone `NSWindow` hosting a
/// centered "Settings not yet migrated from SwiftUI" message. The
/// SwiftUI-based `SettingsView` is intentionally not wired here; it
/// will replace this window controller's content in a follow-up PR.
///
/// Owned by `SettingsWindowCoordinator`; opened from the app menu's
/// ⌘, item. `isReleasedWhenClosed = false` so a reopen reuses the
/// same instance, matching macOS conventions for auxiliary windows.
@MainActor
final class SettingsPlaceholderWindowController: NSWindowController {
    weak var closeDelegate: SettingsPlaceholderWindowCloseDelegate?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        window.contentViewController = PlaceholderViewController(
            message: String(localized: "Settings not yet migrated from SwiftUI"))
        window.center()
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Cleanup channel back to the coordinator when the user closes the
/// window through any path (red button, ⌘W, menu Close, programmatic).
/// Not routed through a `weak` window delegate on the controller so we
/// don't burn the delegate slot — the controller stays a `NSWindowDelegate`
/// through its extension for the close notification alone.
@MainActor
protocol SettingsPlaceholderWindowCloseDelegate: AnyObject {
    func settingsPlaceholderWindowWillClose(
        _ controller: SettingsPlaceholderWindowController)
}

extension SettingsPlaceholderWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        closeDelegate?.settingsPlaceholderWindowWillClose(self)
    }
}

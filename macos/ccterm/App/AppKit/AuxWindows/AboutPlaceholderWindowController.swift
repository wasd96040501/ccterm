import AppKit

/// Placeholder About window — mirrors `SettingsPlaceholderWindowController`.
/// The SwiftUI-based `AboutView` is not wired here; it will replace this
/// controller's content in a follow-up PR.
///
/// Owned by `AboutWindowCoordinator`; opened from the app menu's
/// "About ccterm" item.
@MainActor
final class AboutPlaceholderWindowController: NSWindowController {
    weak var closeDelegate: AboutPlaceholderWindowCloseDelegate?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "About ccterm")
        window.isReleasedWhenClosed = false
        window.contentViewController = PlaceholderViewController(
            message: String(localized: "About not yet migrated from SwiftUI"))
        window.center()
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

@MainActor
protocol AboutPlaceholderWindowCloseDelegate: AnyObject {
    func aboutPlaceholderWindowWillClose(
        _ controller: AboutPlaceholderWindowController)
}

extension AboutPlaceholderWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        closeDelegate?.aboutPlaceholderWindowWillClose(self)
    }
}

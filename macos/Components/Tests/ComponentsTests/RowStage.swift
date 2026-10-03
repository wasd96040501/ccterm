import AppKit

/// A row view in a window off every screen, laid out at `size`, so a test can
/// press it and read where its parts landed. The package's copy of the app's
/// `AppKitStage.mount`, for what a row view does on its own.
@MainActor
final class RowStage {
    let window: NSWindow

    init(_ view: NSView, size: CGSize) {
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    func teardown() {
        window.contentView = nil
        window.close()
    }
}

import AppKit

/// The page's one window: resizable, so each component can be watched across
/// widths, light or dark as the system is.
final class DesignWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CCTerm Design"
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.contentViewController = DesignPageViewController(sections: Design.sections())
        window.setContentSize(NSSize(width: 960, height: 800))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

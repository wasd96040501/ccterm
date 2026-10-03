import AppKit

/// The page's one window: resizable, never narrower than the page's widest
/// host, light or dark as the system is.
final class DesignWindowController: NSWindowController {
    init() {
        let page = DesignPageViewController(sections: Design.sections())
        let width = max(1240, page.minimumWidth)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CCTerm Design"
        window.contentMinSize = NSSize(width: page.minimumWidth, height: 300)
        window.contentViewController = page
        window.setContentSize(NSSize(width: width, height: 800))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

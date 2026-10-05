import AppKit
import DisplayModels

/// The About window: the app's icon, name and build in a title-less window with
/// no resize bit, so it snaps to its content's size. Never restored at launch
/// (`isRestorable = false`); its owner creates it when it is first asked for.
public final class AboutWindowController: NSWindowController {
    /// `icon`: the app's icon, drawn above its name.
    public init(content: AboutContent, icon: NSImage?) {
        let about = AboutViewController(content: content, icon: icon)
        let window = NSWindow(contentViewController: about)
        window.setContentSize(about.preferredContentSize)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = content.windowTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        shouldCascadeWindows = false
        window.center()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

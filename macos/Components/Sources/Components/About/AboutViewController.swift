import AppKit
import DisplayModels
import SwiftUI

/// The About window's content, at the size it fits: what the window holds, and
/// what a host that is not the window shows.
public final class AboutViewController: NSViewController {
    private let content: AboutContent
    private let icon: NSImage?

    /// `icon`: the app's icon, drawn above its name.
    public init(content: AboutContent, icon: NSImage?) {
        self.content = content
        self.icon = icon
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func loadView() {
        let hosting = NSHostingView(rootView: AboutView(content: content, icon: icon))
        view = hosting
        preferredContentSize = hosting.fittingSize
    }
}

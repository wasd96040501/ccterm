import AppKit
import DisplayModels
import SwiftUI

/// The About window's content, at the size it fits: what the window holds, and
/// what a host that is not the window shows. A hosting controller whose
/// `preferredContentSize` follows its view (`sizingOptions`), so the size is
/// SwiftUI's, never measured by hand.
public final class AboutViewController: NSHostingController<AnyView> {
    /// `icon`: the app's icon, drawn above its name.
    public init(content: AboutContent, icon: NSImage?) {
        super.init(rootView: AnyView(AboutView(content: content, icon: icon)))
        sizingOptions = [.preferredContentSize]
    }

    @available(*, unavailable)
    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

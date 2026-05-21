import AppKit
import SwiftUI

/// SwiftUI content that does not capture mouse events, suitable for
/// painting decoration on top of an `NSViewRepresentable`-hosted AppKit
/// view (e.g. the `NSTableView` behind `NativeTranscript2`).
///
/// Why this exists: `.allowsHitTesting(false)` is a SwiftUI-layer flag
/// — it removes the view from SwiftUI's own hit-testing chain. AppKit's
/// `NSView.hitTest(_:)` ignores it, so a SwiftUI overlay sitting on top
/// of an AppKit-backed view still wins hit tests at the AppKit layer
/// and the underlying view never sees the mouse. Wrapping the content
/// in an `NSView` whose own `hitTest(_:)` returns `nil` is what makes
/// AppKit treat the layer as transparent.
///
/// The content itself is rendered through `NSHostingView` so it still
/// participates in the SwiftUI render tree (animations, environment,
/// `@State`, etc. all work as usual). Intended for *decorative*
/// overlays — anything interactive (buttons, gestures) should sit in
/// its own z-layer above this view.
struct PassthroughHostingView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> Container {
        let container = Container()
        let hosting = NSHostingView(rootView: content())
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.hostingView = hosting
        container.addSubview(hosting)
        return container
    }

    func updateNSView(_ nsView: Container, context: Context) {
        nsView.hostingView.rootView = content()
    }

    final class Container: NSView {
        var hostingView: NSHostingView<Content>!
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

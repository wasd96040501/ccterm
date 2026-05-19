import AppKit
import SwiftUI

/// Holder for a weak reference to the detail pane's backing `NSView`. The
/// reference is captured by `DetailBakeProbe` once SwiftUI mounts the probe
/// inside the detail's modifier chain, and used by `RootView2` to grab a
/// bitmap of the *outgoing* detail content right before the sidebar
/// selection flips.
///
/// Why a sibling-class indirection instead of `@State` on the view: the
/// binding-setter intercept on `SidebarView2.selection` needs to run
/// **synchronously inside the setter** (before `selectedSessionId` is
/// assigned, otherwise SwiftUI starts re-evaluating the body and the
/// `.id(sid)` swap begins to dismantle the outgoing `ChatHistoryView`).
/// SwiftUI's `Image(nsImage:)` overlay reads the bitmap on the next
/// render pass — by then the outgoing view is gone. A reference holder
/// gives us a stable thing to call `snapshot()` on at the precise moment
/// of the click.
@MainActor
final class DetailBakeSnapshotter {
    fileprivate weak var probeView: NSView?

    /// Bitmap of the current detail content, or nil if no probe has
    /// registered yet (e.g. before the first detail mount).
    ///
    /// We walk up from the probe to the largest ancestor whose width
    /// matches the probe's own — that's the detail content's container
    /// inside `NSHostingView`. Capturing higher reaches the entire window
    /// (including the sidebar); capturing the probe directly is the
    /// 0-height invisible view itself.
    func snapshot() -> NSImage? {
        guard let probe = probeView else { return nil }
        let host = detailContainer(for: probe) ?? probe
        let bounds = host.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        host.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Walks `view.superview` chain; returns the topmost ancestor whose
    /// bounding-rect width matches `view.bounds.width`. That ancestor is
    /// the NSHostingView-internal container that mirrors the detail
    /// pane's geometry. Stops the moment the width changes (we've
    /// crossed into a wider parent like the split view).
    private func detailContainer(for view: NSView) -> NSView? {
        var current = view
        var best = view
        let targetWidth = view.bounds.width
        guard targetWidth > 0 else { return nil }
        while let parent = current.superview {
            if abs(parent.bounds.width - targetWidth) < 0.5 {
                best = parent
                current = parent
            } else {
                break
            }
        }
        return best
    }
}

/// 0-pt invisible probe that hands its backing `NSView` to a
/// `DetailBakeSnapshotter` on mount. Place it inside the detail
/// modifier chain (e.g. `.background(DetailBakeProbe(snapshotter:))`)
/// so the captured ancestor reflects the detail content's geometry.
struct DetailBakeProbe: NSViewRepresentable {
    let snapshotter: DetailBakeSnapshotter

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Defer the assignment one runloop tick: at `makeNSView` time the
        // view is not yet inserted into the hosting view's hierarchy, so
        // its `superview` chain is empty and `snapshot()` would walk to
        // nowhere. Hop once so SwiftUI's commit pass has finished
        // inserting the probe before we hand the weak ref out.
        DispatchQueue.main.async { [weak view] in
            snapshotter.probeView = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

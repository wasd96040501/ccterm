import AppKit
import SwiftUI

/// Double-buffer overlay for SwiftUI view swaps.
///
/// `ViewTransitionContainer` wraps any `View`. The paired
/// `ViewTransitionController` exposes two operations:
///
/// 1. `bake()` — capture the container's current rendered pixels into
///   an `NSImage` and lock it on top of the live content. Subsequent
///   layout / scroll work in the underlying view is hidden behind the
///   bitmap; user sees frozen pixels.
/// 2. `release()` — drop the overlay. The live content is revealed.
///
/// The intended pattern for session/document switches:
///
///     @State private var transition = ViewTransitionController()
///     ...
///     ViewTransitionContainer(controller: transition) {
///         MyView(id: visibleId).id(visibleId)
///     }
///     .task(id: targetId) {
///         transition.bake()       // snapshot current pixels
///         visibleId = targetId    // re-mount MyView underneath the overlay
///         // wait for the new view to anchor / settle
///         while !target.isReady { try? await Task.sleep(...) }
///         transition.release()    // reveal
///     }
///
/// This is a *generic* component — it doesn't know about chat,
/// sessions, or transcripts. It only cares about a container's pixels
/// and an externally driven readiness signal. Future swap surfaces
/// (e.g. archive → session, demo → chat) can reuse it.
@MainActor
@Observable
final class ViewTransitionController {
    /// Static bitmap rendered on top of the container's content while
    /// non-nil. SwiftUI observes this to drive the overlay layer.
    fileprivate(set) var bakedImage: NSImage?

    /// Backing `NSView` resolved by the embedded probe on attach.
    /// `bake()` is a no-op until this is set — protects callers that
    /// invoke `bake()` before SwiftUI has committed the container.
    fileprivate weak var hostView: NSView?

    /// Capture the container's current rendered pixels and lock them on
    /// top of the live content. Idempotent — calling `bake()` while an
    /// overlay is already up replaces it with the current pixels (which
    /// includes the still-showing overlay; safe under rapid swaps where
    /// a previous bake is still on screen).
    func bake() {
        guard let host = hostView else { return }
        let bounds = host.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        host.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        bakedImage = image
    }

    /// Drop the overlay so the underlying live content is visible.
    /// Idempotent.
    func release() {
        bakedImage = nil
    }
}

/// Wraps `content` and renders a static bitmap on top whenever
/// `controller.bakedImage` is non-nil. The probe inside publishes the
/// container's backing `NSView` to the controller so `bake()` can
/// snapshot it via `cacheDisplay(in:to:)`.
struct ViewTransitionContainer<Content: View>: View {
    let controller: ViewTransitionController
    let content: Content

    init(
        controller: ViewTransitionController,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            // Transparent probe that exposes its enclosing
            // `NSView` (the SwiftUI-managed container holding the
            // ZStack's children) to the controller. We snapshot from
            // *that* superview so the captured pixels include
            // `content` rendered below.
            ViewTransitionProbe(controller: controller)
                .allowsHitTesting(false)
            if let image = controller.bakedImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ViewTransitionProbe: NSViewRepresentable {
    let controller: ViewTransitionController

    func makeNSView(context: Context) -> NSView {
        let v = ProbeView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.controller = controller
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? ProbeView else { return }
        probe.controller = controller
    }

    @MainActor
    fileprivate final class ProbeView: NSView {
        weak var controller: ViewTransitionController? {
            didSet { register() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            register()
        }

        private func register() {
            guard let c = controller else { return }
            if let sv = superview {
                c.hostView = sv
                // Fresh mount → start with no stale overlay. Without
                // this, navigating away from and back to a surface that
                // hosts a `ViewTransitionContainer` could leave a
                // bitmap from the previous interaction painted on
                // first paint.
                c.bakedImage = nil
            }
        }
    }
}

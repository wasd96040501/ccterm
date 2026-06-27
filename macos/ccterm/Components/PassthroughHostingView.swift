import SwiftUI

/// Full-pane host for the permission-card overlay. Two overrides make it a
/// click-through scrim everywhere the card is NOT, so the transcript beneath
/// keeps its clicks and I-beam cursor:
///
/// - `hitTest`: `super.hitTest` returns the deepest SwiftUI subview under the
///   point, or `self` if no subview claims it (the transparent overlay
///   background — `PermissionCardOverlay` never paints a hit-eligible scrim
///   outside the card). We map the `self` case to `nil` so AppKit keeps
///   searching siblings (the scrims, then the table). Points inside the card
///   resolve to a real subview → returned, so the card's buttons work.
/// - `resetCursorRects`: `NSHostingView` otherwise registers a default arrow
///   cursor rect over its full bounds, shadowing the transcript's I-beam. We
///   no-op it. SwiftUI's interactive elements use
///   `NSTrackingArea(.cursorUpdate)` — unaffected.
///
/// Fixed to `NSHostingView<AnyView>` (non-generic): a generic `<Content>`
/// triggers a Swift 6.3 SIL inliner crash on the synthesized
/// `__deallocating_deinit` in Release builds. The same pattern the
/// `restingBarHost` / scrim hosts already follow.
final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    override func resetCursorRects() {
        // Intentionally empty — don't claim the arrow cursor over the whole
        // pane. The transcript below keeps its I-beam.
    }

    nonisolated required init(rootView: AnyView) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

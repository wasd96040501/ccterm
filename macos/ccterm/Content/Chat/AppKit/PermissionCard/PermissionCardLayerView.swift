import AppKit

/// AppKit replacement for `PassthroughHostingView` as the permission card's
/// full-pane host (migration plan §4.4-2). A PLAIN `NSView` (NOT an
/// `NSHostingView`) layered above the transcript + resting bar inside
/// `ChatSessionViewController`. The `PermissionCardController` mounts /
/// dismisses the AppKit card inside it.
///
/// Two overrides make it a click-through scrim everywhere the card is NOT, so
/// the transcript beneath keeps its clicks AND its I-beam cursor — the same
/// contract `PassthroughHostingView.hitTest`/`resetCursorRects`
/// (`PassthroughHostingView.swift:23-31`) implemented, reproduced verbatim on a
/// plain `NSView`:
///
/// - `hitTest`: `super.hitTest` returns the deepest subview under the point, or
///   `self` when no subview claims it (the transparent overlay background — the
///   controller never paints a hit-eligible scrim outside the card). We map the
///   `self` case to `nil` so AppKit keeps searching siblings (the scrims, then
///   the table). Points inside the mounted card resolve to a real subview →
///   returned, so the card's buttons / diff copy button work.
/// - `resetCursorRects`: a plain layer-backed `NSView` does not register a
///   default cursor rect the way `NSHostingView` does, but we no-op it
///   explicitly to PIN the contract: ONLY this layer view is cursor-rect-free
///   (so the transcript I-beam shows through the transparent margin). DESCENDANTS
///   keep normal behavior — `DiffNSView.resetCursorRects` registers
///   `.pointingHand` for its copy button and selectable text wants the I-beam
///   (§4.4-2). The no-op here does not touch descendants.
///
/// **Dismiss hit-through (§4.4-4).** While the card's dismiss fade runs, the
/// card is still in the view tree (it is removed only in the animation
/// completion) but must be hit-transparent — matching SwiftUI's "absent from
/// the tree during transition." `isDismissing` makes `hitTest` return `nil`
/// over the whole host while it is set, so a click during the fade falls
/// straight through to the transcript.
///
/// Sizing: regime-A full-pane, four-edge-pinned. It must publish NO
/// `fittingSize` or the inner card's width-cap could leak up into the window's
/// constraint solver and collapse the window (root `CLAUDE.md` host-sizing +
/// plan R1). `intrinsicContentSize = .zero` severs that path.
@MainActor
final class PermissionCardLayerView: NSView {

    /// Set by `PermissionCardController` for the duration of a dismiss fade.
    /// While true the whole host is hit-transparent (the card is visually
    /// present but the dict-absent-during-transition click-through matches the
    /// SwiftUI overlay's behavior, §4.4-4).
    var isDismissing = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Dismiss-fade window: visually present, hit-transparent. A click here
        // falls through to the transcript (no card removal until the animation
        // completion).
        if isDismissing { return nil }
        let result = super.hitTest(point)
        // `self` is the transparent margin outside the card — keep searching
        // siblings so the transcript keeps its clicks. Any real subview (the
        // card subtree) is returned so the card's buttons stay clickable.
        return result === self ? nil : result
    }

    override func resetCursorRects() {
        // Intentionally empty — don't claim the arrow cursor over the whole
        // pane; the transcript below keeps its I-beam through the transparent
        // margin. ONLY this view is cursor-rect-free; descendants
        // (`DiffNSView` copy button → `.pointingHand`, selectable text →
        // I-beam) register their own rects normally (§4.4-2).
    }

    /// Regime-A: publish `.zero` so the four-edge-pinned full-pane host never
    /// leaks the inner card's `fittingSize` up into the window's constraint
    /// solver (plan R1, gated by `AppKitSwiftUIBoundaryTests` /
    /// `DetailRouterLayoutDiagnosticsTests`).
    override var intrinsicContentSize: NSSize { .zero }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit` so the
    /// `@MainActor` deinit executor hop doesn't abort under
    /// `libswift_Concurrency`.
    nonisolated deinit {}
}

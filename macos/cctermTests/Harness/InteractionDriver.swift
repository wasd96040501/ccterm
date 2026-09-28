import AppKit

/// Synthesizes **real** user interactions on a mounted `AppKitStage`:
/// routes points through the production `hitTest` path. Nothing here calls
/// an internal method to shortcut the gesture — the point is to exercise
/// the same code an actual click would.
///
/// For a gesture that enters AppKit's private
/// `NSApp.nextEvent(inMode: .eventTracking)` loop (a table's drag-select),
/// pre-post the `.leftMouseDragged` / `.leftMouseUp` events with
/// `NSApp.postEvent` before delivering the `.leftMouseDown`: off-screen
/// there is no hardware stream to feed the loop, so it drains the queued
/// events synchronously and the up guarantees it terminates.
@MainActor
struct InteractionDriver {
    let stage: AppKitStage

    init(_ stage: AppKitStage) { self.stage = stage }

    // MARK: - Generic hit-testing

    /// Resolve what `stage.rootView.hitTest` lands on at a point given in
    /// `view`'s coordinate space. The real routing a click takes before it
    /// reaches a responder — use it to assert a point lands on (or passes
    /// through to) the expected view.
    func hitTest(at pointInView: CGPoint, from view: NSView) -> NSView? {
        let windowPoint = view.convert(pointInView, to: nil)
        return stage.rootView.hitTest(windowPoint)
    }

    /// Walk up from `view` to the first enclosing ancestor of type `T`, or
    /// nil. Handy for "did this hit resolve inside that host view."
    func enclosing<T: NSView>(_ type: T.Type, of view: NSView?) -> T? {
        var node = view
        while let cur = node {
            if let match = cur as? T { return match }
            node = cur.superview
        }
        return nil
    }
}

extension AppKitStage {
    /// An `InteractionDriver` bound to this stage.
    var driver: InteractionDriver { InteractionDriver(self) }
}

import AppKit

extension NSAnimationContext {

    /// Runs `body` with no implicit animation and no CoreAnimation actions, so
    /// every frame, opacity and offset it writes lands at once. The list's
    /// model changes land that way, and only a `MotionClock` moves anything
    /// (M3); a host may call in from inside a group that allows implicit
    /// animation, which would otherwise animate each write again.
    @MainActor
    static func withoutAnimation(_ body: () -> Void) {
        let context = current
        let allowed = context.allowsImplicitAnimation
        context.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        context.allowsImplicitAnimation = allowed
    }
}

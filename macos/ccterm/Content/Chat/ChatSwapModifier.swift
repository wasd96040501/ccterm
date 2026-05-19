import SwiftUI

/// Drives a double-buffered session swap on a chat surface. Encapsulates:
///
/// * The state transition: capture the current view's pixels into the
///   `ViewTransitionController`, mark the target's controller as
///   pending-attach, then commit `visibleSessionId = target` so the
///   underlying `ChatHistoryView` re-mounts under the overlay.
/// * The release: a *reactive* `.onChange` on the visible controller's
///   `firstScreenAnchored` fires `release()` the moment the new
///   `NSTableView` lands its anchor-to-tail handshake. No polling.
/// * A 500ms backstop: in case the anchor signal never fires (e.g. a
///   pathological session that never loads), the overlay disappears so
///   the user is never stuck staring at a frozen bake.
///
/// Lives in `Content/Chat/` (not `Components/`) because it is
/// session/`SessionManager`-aware — the abstraction is "chat swap",
/// not "generic view swap". The underlying overlay primitive
/// (`ViewTransitionContainer`) lives in `Components/` and IS generic.
struct ChatSwapModifier: ViewModifier {
    /// User intent — the sid the chat surface should show next. Bound
    /// to `RootView2.effectiveSessionId` in production; bound to a
    /// `TestNavBox` in unit tests so they can drive the same logic.
    let target: String?
    /// The sid actually keying the `ChatHistoryView` under the overlay.
    /// Trails `target` by the duration of the swap and the anchor
    /// handshake.
    @Binding var visibleSessionId: String?
    let transition: ViewTransitionController
    let manager: SessionManager

    /// Resolves the controller that the *current visible* sid points
    /// at — read inside `.onChange` so SwiftUI's Observation tracks
    /// its `firstScreenAnchored` and re-evaluates when the flag
    /// changes. Returns nil during the initial nil-target window.
    private var visibleSessionController: Transcript2Controller? {
        guard let id = visibleSessionId else { return nil }
        return manager.existingSession(id)?.controller
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: target, initial: true) { _, newTarget in
                applyTargetChange(newTarget)
            }
            .onChange(of: visibleSessionController?.firstScreenAnchored) { _, anchored in
                if anchored == true {
                    transition.release()
                }
            }
            .task(id: visibleSessionId) {
                // Backstop: if the anchor signal never fires (e.g. a
                // controller that's perpetually un-anchored for some
                // reason), drop the overlay after 500ms so the user
                // is never staring at a frozen image indefinitely.
                // `.task(id:)` auto-cancels on the next swap, so this
                // never accumulates.
                try? await Task.sleep(for: .milliseconds(500))
                transition.release()
            }
    }

    private func applyTargetChange(_ newTarget: String?) {
        guard let newTarget else {
            transition.release()
            visibleSessionId = nil
            return
        }
        if visibleSessionId == newTarget {
            // Same sid re-targeted (e.g. transient tab change and back,
            // or `.task(initial: true)` firing on first appearance with
            // visibleSessionId already pre-set). Make sure no stale
            // overlay is lingering.
            transition.release()
            return
        }
        let session = manager.prepareDraftSession(newTarget)
        // Trigger history load eagerly — without this, Phase A only
        // starts once `ChatHistoryView.task` mounts. Idempotent for
        // already-loaded sessions.
        session.loadHistory()

        if session.hasRecord {
            // Real session with history (cold-open OR re-entry).
            // `markPendingAttach` injects the `true → false` edge that
            // `.onChange` upstream needs in order to later observe
            // `false → true` and fire `release()`. Without it, a
            // re-entered session whose controller was already anchored
            // would never transition, and the overlay would only drop
            // on the 500ms backstop.
            session.controller.markPendingAttach()
            transition.bake()
        } else {
            // Draft / no-record session — nothing to anchor, no
            // anchor signal will arrive, so don't bake. Just clear any
            // prior overlay and swap.
            transition.release()
        }
        visibleSessionId = newTarget
    }
}

extension View {
    /// Apply the chat double-buffer swap behavior. See `ChatSwapModifier`.
    func chatSwap(
        target: String?,
        visibleSessionId: Binding<String?>,
        transition: ViewTransitionController,
        manager: SessionManager
    ) -> some View {
        modifier(
            ChatSwapModifier(
                target: target,
                visibleSessionId: visibleSessionId,
                transition: transition,
                manager: manager
            )
        )
    }
}

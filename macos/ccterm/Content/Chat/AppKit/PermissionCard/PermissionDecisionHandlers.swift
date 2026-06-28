import AgentSDK

/// The four decision actions for a pending permission, packaged so the card
/// body and `PermissionCardWiringTests` build them the same way. Each closure
/// turns a `PermissionRequest` convenience decision into a
/// `session.respond(to:decision:)` call — keeping the wire-up (which decision
/// maps to which button, and that `updatedInput` survives) in one
/// unit-testable place.
///
/// Lifted out of the SwiftUI `PermissionCardOverlay` (where it lived as
/// `PermissionCardOverlay.Handlers` / `decisionHandlers(for:session:)`) into
/// this kept, SwiftUI-free home (migration plan §4.4 reusedVerbatim + the
/// "decisionHandlers factory location" risk): the AppKit `PermissionCardController`
/// needs the same factory, and `PassthroughHostingView` / the overlay host are
/// being retired. `PermissionCardOverlay.decisionHandlers` survives as a thin
/// forwarding shim so the still-SwiftUI overlay body + `PermissionCardWiringTests`
/// compile unchanged (the SwiftUI per-kind bodies are ported in the parallel
/// fan-out).
struct PermissionDecisionHandlers {
    let onAllowOnce: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void
    let onAllowWithInput: ([String: Any]?) -> Void
}

/// Build the four decision handlers for `pending`, routed through
/// `session.respond(to:decision:)`. Keyed to `pending.id` so a handler set
/// always targets its own card even when multiple are queued
/// (`PermissionCardWiringTests.testHandlersTargetTheirOwnPendingIdWithMultipleQueued`).
@MainActor
func permissionDecisionHandlers(
    for pending: PendingPermission, session: Session
) -> PermissionDecisionHandlers {
    PermissionDecisionHandlers(
        onAllowOnce: {
            session.respond(to: pending.id, decision: pending.request.allowOnce())
        },
        onAllowAlways: {
            session.respond(to: pending.id, decision: pending.request.allowAlways())
        },
        onDeny: {
            session.respond(to: pending.id, decision: pending.request.deny())
        },
        onAllowWithInput: { updated in
            session.respond(
                to: pending.id,
                decision: pending.request.allowOnce(updatedInput: updated))
        }
    )
}

import AgentSDK
import SwiftUI

/// Standalone permission-card view + the home of the four decision handlers.
///
/// Production no longer mounts this in its own host: the permission card is
/// rendered inline by `ChatBottomCluster` (the merged fade + bar + card tree
/// hosted by `ChatSessionViewController.bottomClusterHost`), which calls
/// `decisionHandlers(for:session:)` directly. This type survives for two
/// reasons:
///   1. `decisionHandlers(for:session:)` / `Handlers` package the
///      button→`session.respond(...)` wiring in one unit-testable place
///      (`PermissionCardWiringTests`), shared with `ChatBottomCluster`.
///   2. It renders the full overlay (card bottom-pinned at `chatBottomInset`,
///      resolved through the same `MainSelectionModel` routing) as a single
///      view, which `PermissionCardSnapshotTests` exercises for visual review.
///
/// Session routing mirrors `ChatBottomCluster` exactly — both read the same
/// `MainSelectionModel.selection` through `ChatBottomCluster.content(...)`, so
/// "the cluster renders nothing" implies "this overlay renders nothing" for
/// the same selection. The read path is `session.pendingPermissions.first`
/// (`@Observable`, no cached copy).
struct PermissionCardOverlay: View {
    @Bindable var model: MainSelectionModel
    @Environment(SessionManager.self) private var manager

    var body: some View {
        // Resolve the displayed session the same way the bottom cluster does.
        // `.none` (every non-`.session(_)` selection) renders nothing.
        let content = ChatBottomCluster.content(
            for: model.selection, draftSessionId: model.draftSessionId)
        ZStack(alignment: .bottom) {
            switch content {
            case .none:
                EmptyView()
            case .chat(let sid):
                card(for: sid)
                    .id(sid)
            }
        }
        // Fill the pane and bottom-align the card; the card self-limits +
        // centers inside via its own frame. This standalone overlay keeps the
        // full-pane frame for the snapshot fixture; production renders the
        // card inline in `ChatBottomCluster` instead (no full-pane frame).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The card subtree for one session. `prepareDraftSession` is the same
    /// idempotent get-or-create the bar uses, returning the instance the VC
    /// holds. Reading `session.pendingPermissions.first` each render keeps the
    /// card in lockstep with the runtime without a shadow copy.
    @ViewBuilder
    private func card(for sessionId: String) -> some View {
        let session = manager.prepareDraftSession(sessionId)
        ZStack(alignment: .bottom) {
            if let pending = session.pendingPermissions.first {
                let handlers = Self.decisionHandlers(for: pending, session: session)
                PermissionCardView(
                    request: pending.request,
                    onAllowOnce: handlers.onAllowOnce,
                    onAllowAlways: handlers.onAllowAlways,
                    onDeny: handlers.onDeny,
                    onAllowWithInput: handlers.onAllowWithInput
                )
                .frame(maxWidth: BlockStyle.maxLayoutWidth)
                .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
                .transition(
                    .scale(scale: 0.96, anchor: .bottom)
                        .combined(with: .opacity))
            }
        }
        // Bottom edge flush with the resting bar's bottom (same inset the bar
        // uses), so the card visually extends *up* from there. Only the card
        // animates; nothing here pumps the bar's height.
        .frame(maxWidth: .infinity, alignment: .bottom)
        .padding(.bottom, ChatSessionViewController.chatBottomInset)
        .animation(.smooth(duration: 0.25), value: session.pendingPermissions.first?.id)
    }

    /// The four decision actions for a pending permission, packaged so both
    /// the body and `PermissionCardWiringTests` build them the same way. Each
    /// closure turns a `PermissionRequest` convenience decision into a
    /// `session.respond(to:decision:)` call — keeping the wire-up
    /// (which decision maps to which button, and that `updatedInput` survives)
    /// in one unit-testable place.
    struct Handlers {
        let onAllowOnce: () -> Void
        let onAllowAlways: () -> Void
        let onDeny: () -> Void
        let onAllowWithInput: ([String: Any]?) -> Void
    }

    static func decisionHandlers(for pending: PendingPermission, session: Session) -> Handlers {
        Handlers(
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
}

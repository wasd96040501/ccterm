import AgentSDK
import SwiftUI

/// Full-pane floating overlay that hosts the `PermissionCardView` when the
/// CLI is waiting on a permission decision. Lives in its own dedicated,
/// click-through `PassthroughHostingView` (regime-A: `sizingOptions = []` +
/// four-edge pin) **separate from the input-bar host**, so the card's
/// footprint never pumps the bottom-anchored bar host's intrinsic height —
/// the bar's height is now purely a function of the bar's own content
/// (multi-line input still grows it), never a function of whether a card is
/// pending. The card fades in place above the transcript; the rest of the
/// overlay is transparent and passes clicks through to the table.
///
/// Session routing mirrors `ChatComposeStack` exactly — both read the same
/// `MainSelectionModel.selection` through `ChatComposeStack.content(...)`, so
/// "the bar host renders nothing" implies "the card host renders nothing"
/// for the same selection. That symmetry is what prevents a stale/wrong
/// session's card from rendering on the new transcript during a fast session
/// switch: the moment selection flips, both hosts resolve the new session id
/// together. `.id(sid)` keys the resolved session so SwiftUI rebuilds the
/// card subtree (not just re-renders it) across switches.
///
/// Card content (the `PermissionCardView` + its four decision callbacks) is
/// carried verbatim from the former `ChatRestingBar` ZStack — only the host
/// moved. The read path is still `session.pendingPermissions.first`
/// (`@Observable`, no cached copy).
struct PermissionCardOverlay: View {
    @Bindable var model: MainSelectionModel
    @Environment(SessionManager.self) private var manager

    var body: some View {
        // Resolve the displayed session the same way the input-bar host does.
        // `.none` (every non-`.session(_)` selection) renders nothing, so the
        // card host stays empty exactly when the bar host is empty.
        let content = ChatComposeStack.content(
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
        // centers inside via its own frame. No hit-eligible background is
        // painted, so `PassthroughHostingView` passes through everywhere
        // outside the card.
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
        // uses), so the card visually extends *up* from there — reproduces the
        // pre-overlay position. Only the card animates; the host geometry is
        // fixed (full pane), so nothing pumps the bar host.
        .frame(maxWidth: .infinity, alignment: .bottom)
        .padding(.bottom, ChatSessionViewController.chatBottomInset)
        .animation(.smooth(duration: 0.25), value: session.pendingPermissions.first?.id)
    }

    /// The four decision actions for a pending permission. The canonical
    /// factory now lives in the SwiftUI-free `permissionDecisionHandlers(for:session:)`
    /// (`PermissionDecisionHandlers.swift`) so the AppKit `PermissionCardController`
    /// shares it. This static method + `Handlers` typealias survive as a thin
    /// forwarding shim so the still-SwiftUI overlay body + `PermissionCardWiringTests`
    /// compile unchanged through the parallel per-kind body port (migration plan
    /// §4.4 reusedVerbatim + the "decisionHandlers factory location" risk).
    typealias Handlers = PermissionDecisionHandlers

    static func decisionHandlers(for pending: PendingPermission, session: Session) -> Handlers {
        permissionDecisionHandlers(for: pending, session: session)
    }
}

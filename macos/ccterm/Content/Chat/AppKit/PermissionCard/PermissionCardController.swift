import AppKit
import Observation

/// AppKit coordinator that mounts / dismisses the floating permission card
/// inside `ChatSessionViewController.permissionCardHost` (a
/// `PermissionCardLayerView`). Replaces the SwiftUI `PermissionCardOverlay`'s
/// `session.pendingPermissions.first` reactive read + `.id(sid)` subtree
/// rebuild (migration plan §4.0, §4.4). Created ONCE in the chat VC's
/// `loadView` and lives for its lifetime — `present(sessionId:)` calls
/// `rebind(for:)` to reset the binding in place (never re-create the host),
/// mirroring `Transcript2SheetPresenter`'s ownership.
///
/// **Second reader of session identity, never an owner.** The controller
/// re-derives the `Session` from the `sessionId` the router hands the chat VC
/// (via `sessionManager.prepareDraftSession`, idempotent) and guards
/// `boundSession === session` on every observation wake (mirroring
/// `InputBarController.observeRunning` :430-431). `TranscriptSwapCoordinator`
/// remains the single owner of `currentSession`.
///
/// **Observation (§4.4-3).** `rebind(for:)` arms a re-arming
/// `withObservationTracking` loop over `session.pendingPermissions.first?.id`
/// (a `String?`) AND calls `reconcile()` synchronously immediately after arming
/// — without that construction-time reconcile, a session re-entered with an
/// already-pending permission strands the card (the loop suspends seeing the
/// pending value and never wakes). Each wake re-arms via
/// `DispatchQueue.main.async` (the beforeWaiting hop) so the appear/dismiss
/// animation runs OUTSIDE any transcript-swap `CATransaction.setDisableActions(true)`
/// window (§4.4-4, R16).
///
/// **Animation (D5 — opacity only).** Appear/dismiss animates `alphaValue`
/// 0↔1 over 0.25s (`NSAnimationContext`) — no scale / transform /
/// anchorPoint / position. `removeFromSuperview` only in the dismiss
/// completion; while the fade runs `layerView.isDismissing` makes the card
/// hit-transparent (click-through to the transcript, §4.4-4).
///
/// **Interleaved-fade safety (timing findings #1–#3).** A card whose fade is
/// in flight is parked in `fadingOutCard` (still in the tree until its
/// completion). Every mount / synchronous-dismiss path calls
/// `cancelInFlightFade()` first, which removes that card NOW and bumps a
/// monotonic `dismissGeneration`. The animated-dismiss completion captures the
/// generation at fade start and is a no-op when superseded — so a stale
/// completion can never clobber a newer fade's `isDismissing` flag, two cards
/// never coexist mid-fade, and `stop` / `clearBinding` leave no orphaned async
/// work to fire after teardown (R16).
@MainActor
final class PermissionCardController {

    // MARK: - Constants

    /// Card bottom inset — flush with the resting bar's bottom
    /// (`ChatSessionViewController.chatBottomInset`, `PermissionCardOverlay.swift:82`).
    static let bottomInset: CGFloat = ChatSessionViewController.chatBottomInset
    /// Card horizontal inset (`ChatSessionViewController.detailHorizontalInset`,
    /// `PermissionCardOverlay.swift:71`).
    static let horizontalInset: CGFloat = ChatSessionViewController.detailHorizontalInset
    /// Card max width (transcript column, `PermissionCardView.swift:79`).
    static let maxWidth: CGFloat = BlockStyle.maxLayoutWidth
    /// Appear/dismiss fade duration — `.smooth(duration: 0.25)` reduced to
    /// opacity-only per D5 (`PermissionCardOverlay.swift:83`).
    static let fadeDuration: TimeInterval = 0.25

    // MARK: - Dependencies

    private unowned let layerView: PermissionCardLayerView
    private let sessionManager: SessionManager
    private weak var syntaxEngine: SyntaxHighlightEngine?

    // MARK: - State

    /// The currently bound session (second reader of identity, see above).
    private var boundSession: Session?
    /// Whether the observation loop is live — gated false on `clearBinding` /
    /// `stop` so a late wake from a prior session can't mount its card.
    private var observationActive = false
    /// The mounted card, if any.
    private var mountedCard: PermissionCardContentView?
    /// The pending id the mounted card was built for, so a same-id wake is
    /// idempotent and an id change rebuilds.
    private var mountedPendingId: String?
    /// A card whose dismiss fade is in flight. It is still in `layerView`'s
    /// subviews (removed only in the fade completion) but is no longer the
    /// `mountedCard`. Tracked separately so a NEW mount / a synchronous dismiss
    /// can drop it immediately rather than stacking a second card on top of a
    /// fading one (timing finding #2) or leaving it for an orphaned completion
    /// to remove after teardown (timing finding #3).
    private var fadingOutCard: PermissionCardContentView?
    /// Monotonic token bumped at the top of every mount / dismiss path. The
    /// animated-dismiss completion captures the value at fade start and only
    /// touches `isDismissing` / removes its card if the token is unchanged — so
    /// a stale completion from a superseded fade can't clobber a newer fade's
    /// `isDismissing` flag (timing finding #1).
    private var dismissGeneration = 0

    // MARK: - Init

    init(
        layerView: PermissionCardLayerView,
        sessionManager: SessionManager,
        syntaxEngine: SyntaxHighlightEngine?
    ) {
        self.layerView = layerView
        self.sessionManager = sessionManager
        self.syntaxEngine = syntaxEngine
    }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The mounted card (nil when none). Read-only — tests assert on whether a
    /// card mounted / which session it belongs to.
    var currentCard: PermissionCardContentView? { mountedCard }
    /// The session the controller is currently bound to. Read-only — tests
    /// assert `boundSession === B` after a cross-session switch.
    var currentBoundSession: Session? { boundSession }
    /// The pending id the mounted card was built for, if any.
    var currentMountedPendingId: String? { mountedPendingId }
    /// A card whose dismiss fade is still in flight (nil once removed). Read-only
    /// — tests assert no orphaned fading card lingers after an interleaved mount.
    var currentFadingOutCard: PermissionCardContentView? { fadingOutCard }

    // MARK: - Rebind in place (plan §4.0, §4.4-3)

    /// Bind to `session` (resolved once by the chat VC and handed to BOTH the
    /// transcript coordinator and this controller in the same source phase,
    /// stale-card fix §4.0). Ordering:
    /// (1) cancel A's observation + synchronously dismiss A's card with NO
    ///     animation (the transcript crossfade owns the session-switch
    ///     animation);
    /// (2) set `boundSession = session`;
    /// (3) arm the re-arming `withObservationTracking` over
    ///     `pendingPermissions.first?.id`;
    /// (4) CONSTRUCTION-TIME reconcile — call `reconcile()` synchronously
    ///     immediately after arming (§4.4-3).
    func rebind(for session: Session) {
        // (1) cancel + synchronously dismiss the outgoing card (no animation).
        observationActive = false
        dismissCardSynchronously()

        // (2) bind the new session.
        boundSession = session

        // (3) arm the re-arming observation loop.
        observationActive = true
        observePending(session)

        // (4) construction-time reconcile (§4.4-3 stranded-card fix).
        reconcile()
    }

    /// Clear to an unbound state for the `.none` selection — synchronously
    /// dismiss the card (no animation), cancel observation, drop the session
    /// (mirrors `InputBarController.clearBinding` :301-329).
    func clearBinding() {
        observationActive = false
        dismissCardSynchronously()
        boundSession = nil
    }

    /// Teardown from `ChatSessionViewController.prepareForRemoval()`. Cancel
    /// observation + synchronously dismiss — NO async work that perturbs an
    /// in-flight swap's disabled `CATransaction` (R16). Idempotent.
    func stop() {
        observationActive = false
        dismissCardSynchronously()
        boundSession = nil
    }

    // MARK: - Observation (re-armed withObservationTracking, §4.4-3)

    private func observePending(_ session: Session) {
        withObservationTracking {
            // The String? id of the first pending permission — the minimal
            // dependency that fires on enqueue, dequeue, and reorder.
            _ = session.pendingPermissions.first?.id
        } onChange: { [weak self, weak session] in
            // Wakes land async at beforeWaiting — the appear/dismiss animation
            // runs from this hop, OUTSIDE any transcript-swap disabled
            // CATransaction window (§4.4-4, R16).
            DispatchQueue.main.async {
                guard let self, let session,
                    self.observationActive, self.boundSession === session
                else { return }
                self.reconcile()
                self.observePending(session)
            }
        }
    }

    // MARK: - Reconcile

    /// Read `session.pendingPermissions.first` and mount / update / dismiss the
    /// card to match (§4.4-3). Non-nil + no card (or id changed) → mount + fade
    /// in; nil + card mounted → fade out + remove; same id → idempotent no-op.
    private func reconcile() {
        guard let session = boundSession else { return }
        let pending = session.pendingPermissions.first

        guard let pending else {
            // No pending permission — dismiss any mounted card.
            if mountedCard != nil { dismissCardAnimated() }
            return
        }

        // Same id already mounted → idempotent.
        if mountedPendingId == pending.id, mountedCard != nil { return }

        // A different card was up — drop it synchronously before mounting the
        // new one (no cross-fade between two cards; the new one fades in).
        if mountedCard != nil { dismissCardSynchronously() }

        mountCard(for: pending, session: session)
    }

    // MARK: - Mount / dismiss

    private func mountCard(for pending: PendingPermission, session: Session) {
        // Drop any card whose fade is still in flight BEFORE adding a new one,
        // so two card subviews never coexist (timing finding #2). Bumping the
        // generation also neutralizes the in-flight fade's completion handler
        // (timing finding #1) before we clear `isDismissing`.
        cancelInFlightFade()

        let handlers = permissionDecisionHandlers(for: pending, session: session)
        let card = PermissionCardContentView(
            request: pending.request,
            engine: syntaxEngine,
            onAllowOnce: handlers.onAllowOnce,
            onAllowAlways: handlers.onAllowAlways,
            onDeny: handlers.onDeny,
            onAllowWithInput: handlers.onAllowWithInput)
        card.translatesAutoresizingMaskIntoConstraints = false
        layerView.addSubview(card)

        // Placement: centerX, width <= maxWidth @required, leading >= inset,
        // bottom == host.bottom - bottomInset (PermissionCardOverlay.swift:70-82
        // → AppKit constraints). The inner card publishes no min-width so it
        // can't leak up to the full-pane host (R1).
        let widthCap = card.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth)
        widthCap.priority = .required
        let widthFill = card.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        widthFill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: layerView.centerXAnchor),
            widthCap,
            widthFill,
            card.leadingAnchor.constraint(
                greaterThanOrEqualTo: layerView.leadingAnchor, constant: Self.horizontalInset),
            card.bottomAnchor.constraint(
                equalTo: layerView.bottomAnchor, constant: -Self.bottomInset),
        ])

        mountedCard = card
        mountedPendingId = pending.id

        // Fade in (opacity only, D5). The animation runs from the observation's
        // async beforeWaiting hop (or the synchronous construction-time
        // reconcile) — outside any swap's disabled CATransaction.
        card.alphaValue = 0
        layerView.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            ctx.allowsImplicitAnimation = true
            card.animator().alphaValue = 1
        }
    }

    /// Fade the card out (opacity only, D5) and remove it in the completion.
    /// While the fade runs `layerView.isDismissing` makes the host
    /// hit-transparent so a click falls through to the transcript (§4.4-4).
    /// D6: focus returns to the transcript (`makeFirstResponder(nil)`).
    ///
    /// The fading card moves to `fadingOutCard` (still in the tree) so a NEW
    /// mount / synchronous dismiss can drop it deterministically, and the
    /// completion is gated on the `dismissGeneration` captured at fade start so
    /// a superseded fade can't reset `isDismissing` or remove a card the newer
    /// path already owns (timing findings #1, #2, #3).
    private func dismissCardAnimated() {
        guard let card = mountedCard else { return }
        // A previous fade may still be in flight; drop it now so we never hold
        // two fading cards (and bump the generation so its completion is inert).
        cancelInFlightFade()

        mountedCard = nil
        mountedPendingId = nil
        fadingOutCard = card
        dismissGeneration &+= 1
        let generation = dismissGeneration
        layerView.isDismissing = true
        // D6 — focus returns to the transcript on dismiss.
        layerView.window?.makeFirstResponder(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            ctx.allowsImplicitAnimation = true
            card.animator().alphaValue = 0
        } completionHandler: { [weak self, weak card] in
            guard let self, self.dismissGeneration == generation else {
                // Superseded by a newer mount / dismiss, which already removed
                // this card and owns `isDismissing` — do nothing.
                return
            }
            card?.removeFromSuperview()
            self.fadingOutCard = nil
            self.layerView.isDismissing = false
        }
    }

    /// Remove the card immediately, no animation — for cross-session teardown
    /// (the transcript crossfade owns the session-switch animation, §4.0) and
    /// `stop` / `clearBinding` (NO async work mid-swap, R16). Idempotent. Also
    /// drops any card whose fade is still in flight and neutralizes its pending
    /// completion (timing finding #3).
    private func dismissCardSynchronously() {
        cancelInFlightFade()
        mountedCard?.removeFromSuperview()
        mountedCard = nil
        mountedPendingId = nil
        layerView.isDismissing = false
        // D6 — focus returns to the transcript on dismiss (symmetry with the
        // animated path; load-bearing once the §4.5 AskUserQuestion wizard,
        // which takes first responder, lands).
        layerView.window?.makeFirstResponder(nil)
    }

    /// Drop a card whose dismiss fade is still in flight: remove it from the
    /// tree NOW and bump `dismissGeneration` so the in-flight fade's completion
    /// handler becomes a no-op (it captured the old generation). Clears
    /// `isDismissing` so the host is hit-eligible again for whatever mounts
    /// next. Idempotent.
    private func cancelInFlightFade() {
        guard fadingOutCard != nil else { return }
        dismissGeneration &+= 1
        fadingOutCard?.removeFromSuperview()
        fadingOutCard = nil
        layerView.isDismissing = false
    }
}

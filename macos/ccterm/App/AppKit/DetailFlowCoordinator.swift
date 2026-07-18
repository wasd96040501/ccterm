import AgentSDK
import AppKit
import Combine

/// Detail-scope coordinator: owns which child VC is mounted in the
/// `DetailContainerViewController` slot for a given `MainSelection`, and
/// owns the two app→detail signals that used to live on
/// `DetailRouterViewController`: notification-driven session activation
/// and CLI launch-failure alerts.
///
/// **Data-down / events-up.** Callers (parent coordinator / notification
/// service) write to `route(to:)`; the coordinator updates
/// `SelectionStore` and swaps the container's child accordingly. This is
/// the sole write-back site for coordinator-driven selection changes.
/// Consumers that need to *observe* selection (sidebar highlight, toolbar
/// chips) subscribe to `selectionStore.$selection` — the coordinator does
/// not sink on the store; it mutates it.
///
/// **Same-kind reuse.** A `.session → .session` swap keeps the existing
/// `HistorySessionViewController` mounted and hands it the new session id
/// via `present(sessionId:)`, so the transcript's per-attach crossfade
/// (owned by `TranscriptSwapCoordinator`) does the visual transition
/// instead of a full VC tear-down and rebuild.
@MainActor
final class DetailFlowCoordinator: Coordinator {
    /// Detail-scope dependency bag threaded through to every child VC.
    let detailContext: DetailContext
    /// The single-child container this coordinator drives. Held strong;
    /// its lifetime is bounded by the window controller that owns the
    /// split.
    let container: DetailContainerViewController
    /// Registry / launch-failure sink source. Held for the two owned
    /// wires this coordinator installs at `start()`.
    let sessionManager: SessionManager
    /// App→detail signals; the coordinator is the single, window-lifetime
    /// consumer of `onActivateSession` and calls `bootstrap()` from
    /// `start()`.
    let notifications: NotificationService

    /// Coordinator protocol requirement. Kept intentionally empty — this
    /// flow has no grandchildren, so nothing ever lands here. Not a
    /// candidate for `Never` because the protocol needs a settable
    /// `Array`.
    var childCoordinators: [Coordinator] = []

    /// The kind of child currently mounted in the container. Compared
    /// against `childKind(for:)` on `route(to:)` to decide whether a
    /// full VC swap is needed — same-kind transitions keep the existing
    /// child alive and hand it the new value imperatively.
    private var currentKind: ChildKind?

    /// The routing table's kind space. Kept intentionally coarse: draft
    /// sessions and `.newSession` currently share the "new session
    /// placeholder" kind because both surface the same not-yet-migrated
    /// SwiftUI compose surface. When the draft-landing / compose
    /// migrations land, drafts split off into their own kind.
    enum ChildKind: Equatable {
        case history
        case newSession
        case archive
        case none
    }

    init(
        detailContext: DetailContext,
        container: DetailContainerViewController,
        sessionManager: SessionManager,
        notifications: NotificationService
    ) {
        self.detailContext = detailContext
        self.container = container
        self.sessionManager = sessionManager
        self.notifications = notifications
    }

    // MARK: - Coordinator

    func start() {
        // A notification banner click maps straight to a selection change,
        // routed the same way any other selection change flows. Single
        // owner: no per-VC observation task, no retain cycle.
        notifications.onActivateSession = { [weak self] sid in
            guard let self else { return }
            self.route(to: .session(sid))
        }
        // Launch-failure alert has one owner at the detail scope — matches
        // the pre-refactor placement and keeps the alert presenting even
        // when no history VC is mounted (e.g. the failure lands on a draft
        // session sitting on the placeholder).
        sessionManager.onLaunchFailure = { [weak self] failure in
            guard let self else { return }
            self.presentLaunchFailureAlert(failure)
        }
        // Notification subsystem bootstrap. Idempotent inside the service.
        notifications.bootstrap()
        // Mount the child for whatever selection the store starts at.
        route(to: detailContext.selectionStore.selection)
    }

    // MARK: - Routing

    /// Drive the container to whatever child kind `selection` maps to,
    /// hand the mounted `HistorySessionViewController` the new session id
    /// (for `.history`), and mutate the selection store to match — in
    /// that order. Structural work runs first; the store write is what
    /// lets sidebar / toolbar consumers reflect the new selection.
    ///
    /// Idempotent when `selection` matches the store's current value and
    /// the mounted kind matches; same-kind session flips call
    /// `present(sessionId:)` on the existing history VC without a
    /// full swap.
    func route(to selection: MainSelection) {
        // ① compute the child kind for the incoming selection.
        let kind = childKind(for: selection)

        // ② same-kind reuse: `.history → .history` is the common
        // session→session swap — keep the VC mounted and let its swap
        // coordinator do the transcript crossfade. Every other kind is
        // stateless in this refactor (placeholders), so a same-kind
        // transition is a no-op there.
        if kind == currentKind {
            if kind == .history, case .session(let sid) = selection {
                historyChild()?.present(sessionId: sid)
            }
            // Reflect the store even on same-kind, so a folder→session
            // flip that doesn't cross the kind boundary still lands.
            // `select(_:)` is idempotent for `==` values, so a
            // no-op restore is a no-op.
            detailContext.selectionStore.select(selection)
            return
        }
        currentKind = kind

        // ③ cross-kind swap: new child VC, mount it, settle the frame,
        // then hand the session id to the child. The "settle before
        // present" ordering is what lets the transcript typeset each
        // visible block at exactly ONE width — the §2.19 single-width
        // contract (see NativeTranscript2/CLAUDE.md).
        let child = makeChild(for: kind, selection: selection)
        container.setChild(child, animated: true)
        if kind == .history, case .session(let sid) = selection {
            container.view.layoutSubtreeIfNeeded()
            historyChild()?.present(sessionId: sid)
        }

        // ④ write the store last — the ONE place coordinator-driven
        // selection changes hit it. Sidebar highlight + toolbar chips
        // sink on the store and repaint in the same source phase.
        detailContext.selectionStore.select(selection)
    }

    // MARK: - Helpers

    /// Pure routing decision refined by one runtime fact: a draft
    /// session (still in `.draft` phase, not yet promoted by a first
    /// send) maps to the new-session placeholder rather than the history
    /// transcript. When the draft-landing / compose migrations land in
    /// follow-up PRs, that branch splits off into a `.draftLanding` kind.
    private func childKind(for selection: MainSelection) -> ChildKind {
        switch selection {
        case .none:
            return .none
        case .newSession:
            return .newSession
        case .archive:
            return .archive
        case .session(let sid):
            return sessionManager.isDraftSession(sid) ? .newSession : .history
        }
    }

    /// Build the correct child VC for `kind`. The `selection` parameter is
    /// unused for placeholder kinds but retained so the signature can grow
    /// into "carry the session id into the child's init" once draft-
    /// landing lands with a session-id-carrying VC.
    private func makeChild(
        for kind: ChildKind,
        selection _: MainSelection
    ) -> (NSViewController & DetailContainerChild) {
        switch kind {
        case .history:
            // Composition point for the outline transcript's history
            // source (SPEC §8 decision 6): the concrete `SessionHistory`
            // is chosen here and injected as the `TranscriptHistoryService`
            // metatype; the VC builds `TranscriptStore(historySource:)` +
            // `TranscriptViewController(store:)` from it. Session id is
            // presented after the container mounts + settles the child's
            // frame; see `route(to:)`.
            return HistorySessionViewController(historySource: SessionHistory.self)
        case .newSession:
            return NewSessionPlaceholderViewController()
        case .archive:
            return ArchivePlaceholderViewController()
        case .none:
            // Direct instantiation of the shared placeholder base — no
            // dedicated subclass needed because this landing state has no
            // user-facing name (the sidebar can only reach it via
            // `deselectAll`).
            return PlaceholderViewController(
                message: String(localized: "Nothing selected"))
        }
    }

    /// Downcast helper for the same-kind session flip path.
    private func historyChild() -> HistorySessionViewController? {
        container.currentChild as? HistorySessionViewController
    }

    /// Present the CLI launch-failure alert on the window (or run modal
    /// when detached). Sole owner of the alert — a failure surfaces exactly
    /// one sheet regardless of how many transcript VCs the flow has
    /// mounted through its lifetime.
    private func presentLaunchFailureAlert(_ failure: SessionManager.LaunchFailure) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Failed to launch CLI")
        alert.informativeText = failure.message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.alertStyle = .warning
        if let window = container.view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26 (matches every other `@MainActor` class in the
    /// codebase). The two closure sinks (`onActivateSession`,
    /// `onLaunchFailure`) capture `[weak self]`, so no explicit unwiring
    /// is needed here.
    nonisolated deinit {}
}

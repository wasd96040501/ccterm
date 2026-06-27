import AppKit
import Observation
import SwiftUI

/// A detail child the router can ask to release its per-session resources
/// when it's swapped out on a cross-kind transition. The router drives
/// teardown **explicitly** rather than leaving it to ARC timing: the
/// outgoing child's transcript scroll view, sheet presenter, and
/// `isRunning` observation task are dismantled deterministically the
/// moment it leaves the hierarchy, instead of lingering until the VC
/// happens to deallocate.
@MainActor
protocol DetailRouterChild: NSViewController {
    func prepareForRemoval()
}

/// Empty AppKit container at the detail slot of `MainSplitViewController`.
/// Hosts exactly one child `NSViewController` at a time and swaps it on
/// `MainSelectionModel.selection` changes through proper AppKit VC
/// containment (`addChild` / `removeFromParent` + `view.addSubview` /
/// `removeFromSuperview`).
///
/// The router's purpose is to **let each selection have its own VC**,
/// instead of cramming archive / demos / chat / compose into one
/// always-mounted detail VC and toggling them via overlay opacity +
/// hit-test heuristics. The earlier single-VC shape forced a full-pane
/// `PassthroughHostingView` whose `super.hitTest === self` gate sat on
/// top of the input bar's chrome row and silently swallowed clicks on
/// every plain-style SwiftUI button there. (`PassthroughHostingView`
/// was later re-introduced for the permission-card overlay — but that
/// host is a separate full-pane sibling whose chrome lives in another
/// host beneath it, so its passthrough no longer covers any buttons.)
///
/// Routing table:
/// - `.none` / `.session(_)` → `ChatSessionViewController`
/// - `.newSession` → `ComposeSessionViewController`
/// - `.archive` → `ArchiveViewController`
/// - `.demo(_)` (DEBUG only) → the matching demo VC
///
/// Same-kind transitions (e.g. flipping between two history sessions,
/// both `.transcript`) keep the existing child VC alive — the router
/// drives the child's imperative `present(sessionId:)` to swap the
/// session. Only cross-kind transitions tear down and rebuild.
///
/// ## Sole structural owner of the detail-side transition
///
/// The router is the **only** observer of `MainSelectionModel` for
/// structural purposes — it registers as the model's
/// `selectionObserver` and is driven **synchronously** from
/// `select(_:)`, in the same source phase as the click. It then:
///
/// 1. installs the correct child VC kind (swap only on cross-kind), and
/// 2. for the transcript kind, settles the child's frame and calls
///    `ChatSessionViewController.present(sessionId:)`.
///
/// This collapses what used to be two independent async observers (the
/// router AND the chat VC each watching `model.selection` on separate
/// `withObservationTracking` re-arm hops) into one synchronous path, so
/// "show session X" lands atomically rather than fragmenting across
/// ticks. The chat VC no longer observes selection at all.
///
/// `DetailRouterContainmentTests` pins the invariant that there is
/// always exactly one child and it stays attached to `view` — the
/// regression gate for the whole refactor.
@MainActor
final class DetailRouterViewController: NSViewController, MainSelectionObserver {
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// (`swift_task_deinitOnExecutorImpl`) that aborts in the XCTest
    /// process — the macOS 26 libswift_Concurrency `TaskLocal` teardown bug
    /// the rest of the codebase already guards against. See
    /// `SessionRuntime.swift` for the full writeup.
    nonisolated deinit {}

    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let notifications: NotificationService
    let syntaxEngine: SyntaxHighlightEngine
    let searchBus: TranscriptSearchBus
    let inputDraftStore: InputDraftStore

    /// The kind of VC currently mounted as the single child. Compared
    /// against `childKind(for:)` on selection change to decide whether
    /// a swap is needed — same-kind transitions (e.g. flipping between
    /// two history sessions, both `.transcript`) keep the existing
    /// child VC alive, and the router hands it the new session via
    /// `present(sessionId:)` without paying for a full tree rebuild.
    private(set) var currentKind: ChildKind?

    /// The single mounted child. `private(set)` so containment tests
    /// can read it without widening the swap API.
    private(set) var currentChild: NSViewController?

    /// The outgoing child mid-crossfade, kept mounted (behind the
    /// incoming one) until the fade-out animation completes. `nil` when
    /// no crossfade is in flight. A new swap flushes it synchronously
    /// first (`finishFadeOut`) so rapid sidebar switches collapse rather
    /// than stacking translucent ghosts.
    private var fadingOutChild: NSViewController?

    /// Crossfade duration for a cross-kind detail swap. Short — matches
    /// the snappy feel of a macOS source-list mode change; long enough
    /// to read as a transition rather than a flash. The fade is the only
    /// non-atomic part of the swap: the structural mount + `present` run
    /// synchronously in the click's source phase, then the opacity
    /// animation rides CoreAnimation's own clock from `beforeWaiting`.
    private static let childCrossfadeDuration: CFTimeInterval = 0.18

    /// Gates the first transcript attach until the router's view has a
    /// real frame. The router's `viewDidLoad` runs before the split has
    /// sized the detail item, so the very first `applySelection` (which
    /// runs `layoutSubtreeIfNeeded` + the child's `present`) is deferred
    /// to the first framed `viewDidLayout`. Every selection change after
    /// that is applied synchronously from `selectionDidChange(to:)`.
    private var didInitialApply = false

    init(
        model: MainSelectionModel,
        sessionManager: SessionManager,
        recentProjects: RecentProjectsStore,
        notifications: NotificationService,
        syntaxEngine: SyntaxHighlightEngine,
        searchBus: TranscriptSearchBus,
        inputDraftStore: InputDraftStore
    ) {
        self.model = model
        self.sessionManager = sessionManager
        self.recentProjects = recentProjects
        self.notifications = notifications
        self.syntaxEngine = syntaxEngine
        self.searchBus = searchBus
        self.inputDraftStore = inputDraftStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        // Behind-window vibrancy backdrop for the whole detail half,
        // shared by every child (chat / compose / archive). Replaces the
        // flat opaque `windowBackgroundColor` the NSWindow paints by
        // default: each child VC mounts on top with a transparent view,
        // so the `.contentBackground` material shows through wherever they
        // don't paint (the transcript, the dot-grid compose backdrop, the
        // archive list). `.contentBackground` is the system material for a
        // window's content region beside a source-list sidebar.
        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        view = effect
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Become the model's sole structural observer — `select(_:)`
        // now drives `selectionDidChange(to:)` synchronously.
        model.selectionObserver = self
        // Own the app→detail signals that used to be observed by every
        // (leaky) `ChatSessionViewController`: a notification click maps
        // straight to a selection change. The router is the single,
        // window-lifetime owner, so there's exactly one consumer and no
        // per-detail-VC observation task to retain a torn-down VC.
        notifications.onActivateSession = { [weak self] sid in
            self?.model.select(.session(sid))
        }
        // Likewise own the launch-failure alert here. Per-VC observation
        // stacked one alert per leaked transcript VC; one owner presents
        // exactly one.
        sessionManager.onLaunchFailure = { [weak self] failure in
            self?.presentLaunchFailureAlert(failure)
        }
        // Notification subsystem bootstrap, kicked once per main-window
        // mount from the stable owner. `bootstrap()` guards re-entry.
        notifications.bootstrap()
        // Mount the correct child VC kind for the initial selection. The
        // transcript attach itself rides the first framed `viewDidLayout`
        // (the view has no real frame yet here).
        installChildForCurrentSelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // First framed pass: run the full transition (child kind is
        // already mounted; this adds the transcript attach against the
        // now-settled frame). Subsequent changes come through
        // `selectionDidChange(to:)` synchronously.
        guard !didInitialApply, view.bounds.width > 0, view.bounds.height > 0 else { return }
        didInitialApply = true
        applySelection(model.selection)
    }

    // MARK: - Launch-failure alert

    /// Present the CLI launch-failure alert on the window. Owned here —
    /// the single, window-lifetime detail owner — so a failure surfaces
    /// exactly one alert regardless of how many transcript VCs exist.
    private func presentLaunchFailureAlert(_ failure: SessionManager.LaunchFailure) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Failed to launch CLI")
        alert.informativeText = failure.message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Routing

    enum ChildKind: Equatable {
        case transcript
        case compose
        case draftLanding
        case archive
        #if DEBUG
        case demo(DemoKind)
        #endif
    }

    /// Pure routing decision: which kind of child VC `selection`
    /// should map to. Static + pure so the routing table is directly
    /// unit-testable — see `DetailRouterContainmentTests`.
    ///
    /// `.session(_)` maps to `.transcript` here unconditionally; whether a
    /// session is actually a draft (→ `.draftLanding`) is a *runtime* fact
    /// that needs `SessionManager`, so that refinement lives in the
    /// instance method `resolvedChildKind(for:)`. Keeping this pure means
    /// the basic table stays testable without standing up a manager.
    static func childKind(for selection: MainSelection) -> ChildKind {
        switch selection {
        case .none, .session:
            return .transcript
        case .newSession:
            return .compose
        case .archive:
            return .archive
        #if DEBUG
        case .demo(let kind):
            return .demo(kind)
        #endif
        }
    }

    /// Phase-aware routing decision used by the live router. Refines the
    /// pure `childKind(for:)` table with one runtime fact: a `.session(_)`
    /// that is still a not-yet-sent draft routes to `.draftLanding` (the
    /// no-card landing page), not `.transcript`. Read fresh on every
    /// `applySelection` — never cached — so the draft → active phase flip
    /// on first send swaps the landing VC for the transcript VC in place
    /// (driven by `MainSelectionModel.promote(to:)`).
    ///
    /// `isDraftSession` (not the cache-only `existingSession(_:)?.isDraft`)
    /// so a `.draft` row restored from disk after a cold restart — present in
    /// the sidebar but not yet materialized as a `Session` — still routes to
    /// the landing page instead of falling through to the transcript.
    private func resolvedChildKind(for selection: MainSelection) -> ChildKind {
        if case .session(let sid) = selection,
            sessionManager.isDraftSession(sid)
        {
            return .draftLanding
        }
        return Self.childKind(for: selection)
    }

    /// Ensure the correct child VC **kind** is mounted for the current
    /// selection — swap only on a cross-kind change, reuse otherwise.
    /// Does NOT attach a session; the transcript attach is driven
    /// separately by `applySelection` via `present(sessionId:)`. Called
    /// from `applySelection` (with `animated: true`) and directly by
    /// `DetailRouterContainmentTests` (which assert tree shape without a
    /// window, so they take the synchronous path). Idempotent when the
    /// kind is unchanged.
    ///
    /// When `animated` and there's an outgoing child AND we're in a
    /// window, the swap stages a crossfade: the incoming child is mounted
    /// **on top** of the still-live outgoing one at `alpha == 0`, and the
    /// outgoing child is parked in `fadingOutChild`. The actual fade is
    /// kicked by `commitChildTransition()` *after* `applySelection` has
    /// run `present` on the incoming transcript — so the structural mount
    /// stays synchronous (settled frame, one-width typeset) and only the
    /// cosmetic fade is deferred to CoreAnimation. Without a window (tests,
    /// cold start) it falls back to the synchronous teardown-then-mount.
    func installChildForCurrentSelection(animated: Bool = false) {
        let kind = resolvedChildKind(for: model.selection)
        if kind == currentKind, currentChild != nil { return }

        // Flush any still-running crossfade synchronously before staging a
        // new one, so rapid sidebar switches collapse (the older outgoing
        // child snaps out) instead of stacking translucent ghosts. The
        // late completion for the flushed child no-ops via its guard.
        finishFadeOut()

        let old = currentChild
        let crossfade = animated && old != nil && view.window != nil

        let child = makeChild(for: kind)
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        // Default `addSubview` z-order puts the incoming child ON TOP of
        // the outgoing one, mirroring `attachSession`'s build-in-front
        // ordering so the crossfade composites new-over-old.
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        currentKind = kind
        currentChild = child

        if crossfade, let old {
            child.view.wantsLayer = true
            old.view.wantsLayer = true
            child.view.alphaValue = 0
            fadingOutChild = old
        } else if let old {
            // Synchronous path (no window / not animated): tear the
            // outgoing child's per-session resources down before it leaves
            // the tree — deterministic, not at the mercy of ARC timing.
            (old as? DetailRouterChild)?.prepareForRemoval()
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
    }

    /// Run the staged crossfade, if `installChildForCurrentSelection`
    /// parked an outgoing child. Fades the incoming child in and the
    /// outgoing child out together, tearing the outgoing one down on
    /// completion. No-op when nothing is staged (same-kind reuse,
    /// synchronous path, or initial mount). Called from `applySelection`
    /// only after `present` has made the incoming transcript content live,
    /// so the first composited fade frame already shows real content.
    private func commitChildTransition() {
        guard let outgoing = fadingOutChild, let incoming = currentChild else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.childCrossfadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            incoming.view.animator().alphaValue = 1
            outgoing.view.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.finishFadeOut(expected: outgoing)
        }
    }

    /// Tear down the outgoing crossfade child. Idempotent and called from
    /// two places: the animation completion (with `expected` set), and
    /// synchronously at the head of a new swap to flush an in-flight fade
    /// (no `expected`). The `expected` guard makes a late completion for
    /// an already-flushed child a no-op.
    private func finishFadeOut(expected: NSViewController? = nil) {
        guard let outgoing = fadingOutChild else { return }
        if let expected, expected !== outgoing { return }
        fadingOutChild = nil
        (outgoing as? DetailRouterChild)?.prepareForRemoval()
        outgoing.view.removeFromSuperview()
        outgoing.removeFromParent()
    }

    private func makeChild(for kind: ChildKind) -> NSViewController {
        switch kind {
        case .transcript:
            return ChatSessionViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                syntaxEngine: syntaxEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        case .compose:
            return ComposeSessionViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                syntaxEngine: syntaxEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        case .draftLanding:
            return DraftSessionLandingViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                syntaxEngine: syntaxEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        case .archive:
            return ArchiveViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                syntaxEngine: syntaxEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        #if DEBUG
        case .demo(let demoKind):
            return makeDemoChild(demoKind)
        #endif
        }
    }

    #if DEBUG
    private func makeDemoChild(_ kind: DemoKind) -> NSViewController {
        switch kind {
        case .transcript:
            return TranscriptDemoViewController(syntaxEngine: syntaxEngine)
        case .transcriptStress:
            return TranscriptStressViewController(syntaxEngine: syntaxEngine)
        case .transcriptPerf:
            return TranscriptPerfDemoViewController(syntaxEngine: syntaxEngine)
        case .permissionSession:
            return PermissionSessionDemoViewController(syntaxEngine: syntaxEngine)
        case .permissionCards:
            // The only demo that's a pure SwiftUI view — host it via
            // `NSHostingController` so the surrounding `addChild`
            // plumbing matches the other branches. Same environment
            // injections the production app uses.
            let root = AnyView(
                PermissionCardsDemoView()
                    .environment(sessionManager)
                    .environment(recentProjects)
                    .environment(inputDraftStore)
                    .environment(\.syntaxEngine, syntaxEngine)
            )
            let host = NSHostingController(rootView: root)
            // Fill-the-pane detail child — clear `sizingOptions` so the
            // SwiftUI body's fitting size doesn't bubble up through the
            // split's `view.fittingSize` and collapse the window height
            // (see `ArchiveViewController` for the full rationale). The
            // router pins this view to the detail slot.
            host.sizingOptions = []
            return host
        }
    }
    #endif

    // MARK: - Selection transition (synchronous)

    /// `MainSelectionObserver` — driven synchronously from
    /// `MainSelectionModel.select(_:)`, in the same source phase as the
    /// caller (a sidebar click, a notification activation, etc).
    func selectionDidChange(to selection: MainSelection) {
        // Before the first framed layout there is nothing to attach a
        // transcript to — just keep the child kind in sync; the initial
        // `applySelection` rides `viewDidLayout`.
        guard isViewLoaded else { return }
        guard didInitialApply else {
            installChildForCurrentSelection()
            return
        }
        applySelection(selection)
    }

    /// The whole detail-side transition in one synchronous pass:
    /// install the correct child VC kind (swap only on cross-kind),
    /// then — for the transcript kind — settle the child's frame and
    /// hand it the new session imperatively. Compose / archive / demo
    /// children manage their own content, so the router stops at the
    /// child swap for them.
    private func applySelection(_ selection: MainSelection) {
        // Policy: only animate when the target is "fresh content" — the
        // New Session card, the Archive, or the FIRST entry into a history
        // session. Warm re-entry of an already-viewed session is instant.
        // Computed before `present` runs `loadHistory` (which flips the
        // state off `.notLoaded`). Threads into both transition layers: the
        // cross-kind child swap below, and the same-kind transcript swap
        // inside `present` → `attachSession`.
        let animate = shouldAnimateTransition(to: selection)
        installChildForCurrentSelection(animated: animate)
        let kind = resolvedChildKind(for: selection)
        if kind == .transcript || kind == .draftLanding {
            // Settle the freshly-(re)mounted child so the transcript attach
            // typesets at the final width (the §2.19 single-width contract).
            view.layoutSubtreeIfNeeded()
            let sessionId: String?
            if case .session(let sid) = selection { sessionId = sid } else { sessionId = nil }
            if kind == .transcript {
                (currentChild as? ChatSessionViewController)?
                    .present(sessionId: sessionId, animated: animate)
            } else {
                // A draft session: hand the id to the landing VC, which
                // renders the no-card metadata + draft input bar. On first
                // send the session promotes `.draft → .active`;
                // `MainSelectionModel.promote(to:)` re-fires this path and
                // `resolvedChildKind` now returns `.transcript`, swapping in
                // the live transcript VC.
                (currentChild as? DraftSessionLandingViewController)?
                    .present(sessionId: sessionId, animated: animate)
            }
        }
        // Kick the staged crossfade (if a cross-kind swap parked an
        // outgoing child) now that the incoming content is live. No-op for
        // same-kind reuse and the synchronous (no-window) path.
        commitChildTransition()
    }

    /// Whether a transition INTO `selection` should crossfade. True only
    /// for the three "fresh content" targets — `.newSession`, `.archive`,
    /// and a **first** entry into a history session (history not yet
    /// loaded). A warm re-entry of an already-viewed session, `.none`, and
    /// demos are instant. The session check reads `historyLoadState` via
    /// the non-creating `existingSession` lookup; an unmaterialized session
    /// (never opened) is treated as a first entry.
    private func shouldAnimateTransition(to selection: MainSelection) -> Bool {
        switch selection {
        case .newSession, .archive:
            return true
        case .session(let sid):
            let state = sessionManager.existingSession(sid)?.historyLoadState ?? .notLoaded
            return state == .notLoaded
        case .none:
            return false
        #if DEBUG
        case .demo:
            return false
        #endif
        }
    }
}

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
/// hit-test heuristics. The earlier single-VC shape was what forced
/// the now-deleted `PassthroughHostingView` and its "is super.hitTest
/// === self" gate to exist (which then silently dropped clicks on
/// every plain-style SwiftUI button in the input bar's chrome row).
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
    let searchEngine: SyntaxHighlightEngine
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

    /// A frozen bitmap of the outgoing child, fading out behind the
    /// incoming one. `nil` when no crossfade is in flight. We fade a
    /// **snapshot** — not the live outgoing view — because the outgoing VC
    /// can re-render mid-fade and blank its own content: promotion flips
    /// `.newSession → .session(_)` and fires `refreshRecords()`, and the
    /// compose card's "Recent Sessions" list observes `manager.records`, so
    /// a live fade would show the card's elements vanish the instant the
    /// message is sent. Snapshotting in the swap's source phase (before
    /// SwiftUI re-evaluates at `beforeWaiting`) captures the last good
    /// frame; the live VC is then torn down immediately so it never paints
    /// the blanked state. A new swap flushes the snapshot synchronously
    /// (`finishFadeOut`) so rapid switches collapse rather than stack.
    private var fadingOutSnapshot: NSView?

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
        searchEngine: SyntaxHighlightEngine,
        searchBus: TranscriptSearchBus,
        inputDraftStore: InputDraftStore
    ) {
        self.model = model
        self.sessionManager = sessionManager
        self.recentProjects = recentProjects
        self.notifications = notifications
        self.searchEngine = searchEngine
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
        case archive
        #if DEBUG
        case demo(DemoKind)
        #endif
    }

    /// Pure routing decision: which kind of child VC `selection`
    /// should map to. Static + pure so the routing table is directly
    /// unit-testable — see `DetailRouterContainmentTests`.
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
    /// **on top** at `alpha == 0`, a frozen snapshot of the outgoing child
    /// is parked **behind** it in `fadingOutSnapshot`, and the live
    /// outgoing VC is torn down immediately (so it can't re-render and
    /// blank its content mid-fade — see `fadingOutSnapshot`). The actual
    /// fade is kicked by `commitChildTransition()` *after* `applySelection`
    /// has run `present` on the incoming transcript — so the structural
    /// mount stays synchronous (settled frame, one-width typeset) and only
    /// the cosmetic fade is deferred to CoreAnimation. Without a window
    /// (tests, cold start) it falls back to the synchronous
    /// teardown-then-mount.
    func installChildForCurrentSelection(animated: Bool = false) {
        let kind = Self.childKind(for: model.selection)
        if kind == currentKind, currentChild != nil { return }

        // Flush any still-running crossfade synchronously before staging a
        // new one, so rapid sidebar switches collapse (the older outgoing
        // snapshot snaps out) instead of stacking translucent ghosts.
        finishFadeOut()

        let old = currentChild
        // Snapshot BEFORE mounting/tearing anything down, while the outgoing
        // view still shows its last good frame (SwiftUI hasn't re-evaluated
        // this source phase yet).
        let snapshot = (animated && view.window != nil) ? old.flatMap { snapshotView(of: $0.view) } : nil

        let child = makeChild(for: kind)
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        // Default `addSubview` z-order puts the incoming child ON TOP of
        // the outgoing snapshot, mirroring `attachSession`'s build-in-front
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

        // Tear the outgoing VC down NOW regardless of path — deterministic,
        // not at the mercy of ARC timing, and (when animating) so it stops
        // observing before it can paint a blanked frame.
        if let old {
            (old as? DetailRouterChild)?.prepareForRemoval()
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        if let snapshot {
            child.view.wantsLayer = true
            child.view.alphaValue = 0
            // Insert the frozen snapshot behind the incoming child.
            view.addSubview(snapshot, positioned: .below, relativeTo: child.view)
            snapshot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                snapshot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                snapshot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                snapshot.topAnchor.constraint(equalTo: view.topAnchor),
                snapshot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            fadingOutSnapshot = snapshot
        }
    }

    /// Run the staged crossfade, if `installChildForCurrentSelection`
    /// parked an outgoing snapshot. Fades the incoming child in and the
    /// snapshot out together, removing the snapshot on completion. No-op
    /// when nothing is staged (same-kind reuse, synchronous path, or
    /// initial mount). Called from `applySelection` only after `present`
    /// has made the incoming transcript content live, so the first
    /// composited fade frame already shows real content.
    private func commitChildTransition() {
        guard let snapshot = fadingOutSnapshot, let incoming = currentChild else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.childCrossfadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            incoming.view.animator().alphaValue = 1
            snapshot.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.finishFadeOut(expected: snapshot)
        }
    }

    /// Remove the parked outgoing snapshot. Idempotent and called from two
    /// places: the animation completion (with `expected` set), and
    /// synchronously at the head of a new swap to flush an in-flight fade
    /// (no `expected`). The `expected` guard makes a late completion for an
    /// already-flushed snapshot a no-op. The outgoing VC is already gone
    /// (torn down at swap time), so there's nothing else to release here.
    private func finishFadeOut(expected: NSView? = nil) {
        guard let snapshot = fadingOutSnapshot else { return }
        if let expected, expected !== snapshot { return }
        fadingOutSnapshot = nil
        snapshot.removeFromSuperview()
    }

    /// A frozen bitmap of `source` wrapped in a layer-backed image view,
    /// sized to its current bounds. Captured via `cacheDisplay`, which
    /// renders the CURRENT view tree — and since this runs in the swap's
    /// source phase, before SwiftUI's `beforeWaiting` re-evaluation, it
    /// freezes the last good frame even though the underlying `@Observable`
    /// state (selection, `manager.records`) has already flipped. Returns
    /// `nil` if the view hasn't been laid out yet (no frame to snapshot).
    private func snapshotView(of source: NSView) -> NSView? {
        let bounds = source.bounds
        guard bounds.width > 0, bounds.height > 0,
            let rep = source.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        source.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        return imageView
    }

    private func makeChild(for kind: ChildKind) -> NSViewController {
        switch kind {
        case .transcript:
            return ChatSessionViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                searchEngine: searchEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        case .compose:
            return ComposeSessionViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                searchEngine: searchEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        case .archive:
            return ArchiveViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                searchEngine: searchEngine,
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
            return TranscriptDemoViewController(syntaxEngine: searchEngine)
        case .transcriptStress:
            return TranscriptStressViewController(syntaxEngine: searchEngine)
        case .transcriptPerf:
            return TranscriptPerfDemoViewController(syntaxEngine: searchEngine)
        case .permissionSession:
            return PermissionSessionDemoViewController(syntaxEngine: searchEngine)
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
                    .environment(\.syntaxEngine, searchEngine)
                    .environment(searchBus)
                    .environment(notifications)
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
        if Self.childKind(for: selection) == .transcript {
            // Settle the freshly-(re)mounted child so the transcript attach
            // typesets at the final width (the §2.19 single-width contract).
            view.layoutSubtreeIfNeeded()
            let sessionId: String?
            if case .session(let sid) = selection { sessionId = sid } else { sessionId = nil }
            (currentChild as? ChatSessionViewController)?
                .present(sessionId: sessionId, animated: animate)
        }
        // Kick the staged crossfade (if a cross-kind swap parked an
        // outgoing child) now that the incoming content is live. No-op for
        // same-kind reuse and the synchronous (no-window) path.
        commitChildTransition()
    }

    /// Whether a transition INTO `selection` should crossfade. True for
    /// the "fresh content" targets — `.newSession`, `.archive`, a **first**
    /// entry into a history session (history not yet loaded), and entering
    /// a session **from the New Session card** (`currentKind == .compose`).
    /// A warm re-entry of an already-viewed session, `.none`, and demos are
    /// instant.
    ///
    /// The compose→session case covers promotion: sending the first message
    /// flips `.newSession → .session(_)`, and the promoted session is
    /// already `.loaded` (its runtime is created with `historyLoadState =
    /// .loaded` to skip a no-op JSONL replay), so the `.notLoaded` check
    /// below would miss it. `currentKind` is read here — before
    /// `installChildForCurrentSelection` swaps the child — so it still holds
    /// the OUTGOING kind. Resuming an existing session from the card hits
    /// the same branch, which is the consistent "entered a session from
    /// compose" feel.
    ///
    /// The history-session check reads `historyLoadState` via the
    /// non-creating `existingSession` lookup; an unmaterialized session
    /// (never opened) is treated as a first entry.
    private func shouldAnimateTransition(to selection: MainSelection) -> Bool {
        switch selection {
        case .newSession, .archive:
            return true
        case .session(let sid):
            if currentKind == .compose { return true }
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

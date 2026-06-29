import AppKit
import Combine
import Observation
import SwiftUI

/// Child VC the `DetailRouterViewController` mounts for chat-bearing
/// selections (`.session(_)` / `.none`). Owns the transcript
/// `Transcript2ScrollView` directly — created in `loadView()` so the
/// table's mount + `frameDidChange` cascade lives in AppKit's source
/// phase, not in SwiftUI's commit pass (the whole point of #195).
///
/// This VC does **not** observe `MainSelectionModel`. The router is the
/// sole structural owner and drives the session swap imperatively via
/// `present(sessionId:)` — called synchronously once this VC is mounted
/// AND framed, so the attach always runs against a settled frame (no
/// deferred-attach machinery) and lands in the same source phase as the
/// click that triggered it.
///
/// New Session (`.newSession`) is NOT handled here — it has its own
/// `ComposeSessionViewController`. That split is deliberate: when
/// compose and chat shared this VC's one always-mounted bar host, the
/// host had to morph between full-bleed (compose) and bottom-anchored
/// (chat), and the constraint switch couldn't stay in sync with the
/// SwiftUI body across runloop phases — the full-bleed host lingered
/// over the transcript after a fast switch and swallowed its clicks.
/// With compose gone, the bar host here is *always* bottom-anchored
/// and only ever renders the chat resting bar (or nothing for `.none`),
/// so it never covers more of the transcript than the bar itself.
///
/// Around the transcript we mount full-bleed overlays, all attached for
/// the lifetime of the VC; their *contents* react to `present(sessionId:)`:
/// - top scrim — `TranscriptTopScrimView` (AppKit, hitTest passthrough)
/// - bottom scrim — `TranscriptBottomScrimView` (AppKit, hitTest
///   passthrough, even-odd cutouts at the attach button + pill)
/// - input bar — `restingBarHost` (a pure-AppKit `RestingBarContainerView`,
///   migration plan §4.0/§4.1). It hosts a once-built child
///   `InputBarController` (the pill + chrome row), rebound in place via
///   `rebind(sessionId:)`. The bar is built ONCE in `loadView` and lives for
///   the VC's lifetime — `present(sessionId:)` only resets the model fields,
///   so the bar's frame/constraints never change on a session switch and
///   contribute nothing to `attachSession`'s single-width typeset pass.
/// - permission card — `permissionCardHost` (a plain pure-AppKit
///   `PermissionCardHostView`), a dedicated full-pane click-through host
///   **on top** of the bar, driven by a once-built `permissionCardController`
///   (migration plan §4.0/§4.4). The card floats here instead of inside the
///   bar host so its footprint never pumps the bar host's height.
///
/// The bar host is bottom-anchored and takes only the bar's own intrinsic
/// height, so the transcript scroll view receives clicks in the scrim band
/// above it (and everywhere outside the permission card).
@MainActor
final class ChatSessionViewController: NSViewController, DetailRouterChild {
    /// Coordinate-space identifier for SwiftUI `GeometryReader`/
    /// `PreferenceKey` callbacks that report the attach button +
    /// pill rects. The canonical name for the detail pane's coordinate
    /// space, shared with `ComposeSessionViewController`'s compose card.
    /// The chat bar no longer uses it (it reports rects via AppKit
    /// `convert(_:to:)`); it survives only for compose/draft until Phase 4.
    static let detailCoordSpace = "ChatSessionViewController.detail"
    /// Top fade band height. Sized to match the unified toolbar so the
    /// gradient fades in exactly the strip the toolbar visually covers.
    private static let topFadeScrimHeight: CGFloat = 52
    /// Bottom fade band height. Sized to match the input bar's top
    /// edge, so the gradient stops where the bar begins. Derived from
    /// `chatBottomInset` (36) + `ChromeRowView` row (~22) +
    /// `RestingBarContainerView.barSpacing` (10) + `InputBarView` pill
    /// (32) = 100. Hardcoded — those constants don't change at runtime.
    private static let bottomFadeScrimHeight: CGFloat = 100
    static let composeMaxWidth: CGFloat = 512
    static let chatBottomInset: CGFloat = 36
    static let detailHorizontalInset: CGFloat = 20
    static let detailVerticalInset: CGFloat = 20

    /// The detail-scope dependency bag, handed down from the router.
    /// `model` and the four injected services are read through this.
    let context: DetailContext

    /// Owns the transcript-swap state machine (build / bind / anchor /
    /// crossfade / tear-down + the per-attach turn-usage + `isRunning`
    /// sinks). The VC keeps "what the pane shows" (scrims, resting bar,
    /// permission-card host, focus, cutouts); the coordinator owns the
    /// transcript-attach mechanism and is the single owner of
    /// `currentSession`. Lazily built on first `present` so it can capture
    /// `view` (`loadView` has run by then). Released when the VC deinits;
    /// `prepareForRemoval` / `present(nil)` tear the transcript down through
    /// it without dropping the coordinator itself.
    private var swapCoordinator: TranscriptSwapCoordinator?
    /// Full-bleed overlays. All three are added to `view` once and
    /// stay mounted for the lifetime of the VC. The scrims are pure
    /// AppKit (no `NSHostingView` so they don't register cursor rects
    /// that would shadow the transcript's I-beam).
    private var topScrim: TranscriptTopScrimView!
    private var bottomScrim: TranscriptBottomScrimView!

    /// The once-built input bar. A child `NSViewController` (NOT a
    /// `DetailRouterChild`) added in `loadView`; its `view` (the pill) and its
    /// `chromeRow` are stacked inside `restingBarHost`. `present(sessionId:)`
    /// calls `rebind(sessionId:)` to reset its model fields in place — never
    /// re-`addChild` (a freshly-added child resolving its intrinsicContentSize
    /// would corrupt `attachSession`'s single-width typeset pass, plan §4.0).
    private(set) var inputBarController: InputBarController!

    // `internal` (not `private`) is an access-modifier-only test seam: the
    // `HostedComponentCenteringTests` CI gate samples this host's frame to
    // assert the regime-B centering + width-cap contract. No behavior change.
    // It is now a pure-AppKit `RestingBarContainerView` hosting the input bar
    // child VC; it carries the SAME five regime-B constraints the SwiftUI
    // `NSHostingView<ChatComposeHostRoot>` used to, plus an intrinsic height so
    // the host shrinks to the bar's content (the regime-B contract).
    var restingBarHost: RestingBarContainerView!

    /// Full-pane floating host for the permission card. A plain
    /// `PermissionCardHostView` (regime-A: `intrinsicContentSize = .zero` +
    /// four-edge pin) layered **above** the transcript and `restingBarHost`.
    /// `permissionCardController` mounts the AppKit card inside it; because this
    /// host's geometry is the full pane (not driven by the card), the bar
    /// host's intrinsic height stays a pure function of the bar content — the
    /// card never pumps the bar band. Clicks outside the card pass straight
    /// through to the transcript (see `PermissionCardHostView`).
    var permissionCardHost: PermissionCardHostView!

    /// The once-built permission-card coordinator (migration plan §4.0/§4.4).
    /// Owned by this VC (not a `DetailRouterChild`), mirroring
    /// `Transcript2SheetPresenter` ownership. `present(sessionId:)` calls
    /// `rebind(for:)` to bind it to the shown session in place; `nil` →
    /// `clearBinding()`; teardown → `stop()`.
    private(set) var permissionCardController: PermissionCardController!

    /// Latest attach / pill rects reported by the input bar, converted to
    /// `inputBarController.view` (the scrim anchor). Used to drive
    /// `bottomScrim`'s cutouts. Local to this VC — there's no cross-VC consumer
    /// that would need to read these.
    private var lastAttachRect: CGRect = .zero
    private var lastPillRect: CGRect = .zero

    init(context: DetailContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        // The detail router's `NSVisualEffectView` paints the vibrancy
        // backdrop behind the transcript scroll view (which sets
        // `drawsBackground = false`) — we just need a plain transparent
        // container view here.
        view = NSView()

        topScrim = TranscriptTopScrimView(bandHeight: Self.topFadeScrimHeight)
        topScrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topScrim)

        bottomScrim = TranscriptBottomScrimView(bandHeight: Self.bottomFadeScrimHeight)
        bottomScrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomScrim)

        // Build the input bar ONCE (plan §4.0). It is a child VC so its
        // child-VC lifecycle (`viewDidAppear` gating autofocus) fires; the
        // chat resting bar leaves `autofocus` false. The closures are wired
        // directly into init — no `ChatComposeHostRoot` relay.
        let inputBar = InputBarController(
            sessionManager: context.sessionManager,
            inputDraftStore: context.inputDraftStore,
            onBuiltinCommand: { [weak self] command in
                guard let self, let sessionId = self.inputBarController.boundSessionId else {
                    return
                }
                runBuiltinSlashCommand(
                    command,
                    currentSessionId: sessionId,
                    sessionManager: self.context.sessionManager,
                    model: self.context.model)
            },
            onSubmit: { [weak self] submission, sessionId in
                guard let self else { return }
                submitSessionInput(
                    submission,
                    sessionId: sessionId,
                    sessionManager: self.context.sessionManager,
                    recentProjects: self.context.recentProjects,
                    model: self.context.model)
            })
        addChild(inputBar)
        inputBarController = inputBar
        // Force the child's `loadView` now so `barView` / `chromeRow` exist
        // before we wire the scrim anchor + build the host container (the bar's
        // implicitly-unwrapped `barView` is nil until its view loads).
        inputBar.loadViewIfNeeded()

        // Scrim cutout data path: the bar reports its attach/pill rects
        // converted TO `inputBarController.view` (the new `convert(from:)`
        // anchor, plan §4.1-2 / R6). The consume side converts FROM that
        // exact view.
        inputBar.barView.scrimAnchorView = inputBar.view
        inputBar.barView.onAttachRect = { [weak self] rect in
            guard let self else { return }
            self.lastAttachRect = rect
            self.applyScrimCutouts()
        }
        inputBar.barView.onPillRect = { [weak self] rect in
            guard let self else { return }
            self.lastPillRect = rect
            self.applyScrimCutouts()
        }

        // The regime-B host: a pure-AppKit container stacking the pill + the
        // chrome row, applying the chat bar's inner width-cap + insets (the
        // SwiftUI `ChatRestingBar` padding/frame chain, now in constraints).
        restingBarHost = RestingBarContainerView(
            barView: inputBar.barView,
            chromeRow: inputBar.chromeRow,
            innerMaxWidth: Self.composeMaxWidth,
            horizontalInset: Self.detailHorizontalInset,
            bottomInset: Self.chatBottomInset,
            barSpacing: RestingBarContainerView.barSpacing)
        restingBarHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(restingBarHost)

        // WIDTH is owned by AppKit, HEIGHT by the content (the container
        // publishes its intrinsic height — pill + spacing + chrome + bottom
        // inset). The five regime-B constraints are inherited VERBATIM from the
        // SwiftUI host they replace:
        // - centerX  → the bar is horizontally centered in the pane.
        // - width <= maxHostWidth (required) caps the host; the input pill
        //   (`composeMaxWidth`) self-centers inside via the container's own
        //   inner cap. The cap is the transcript column width
        //   (`BlockStyle.maxLayoutWidth`) plus horizontal padding — kept aligned
        //   with the column so the bar's centered axis matches the transcript's.
        // - width == maxHostWidth @high fills up to that cap on a wide pane,
        //   but yields to `leading >=` on a pane narrower than the cap (detail
        //   can be as small as 680) so the bar shrinks to fit the pane instead
        //   of overflowing its edges.
        let maxHostWidth = BlockStyle.maxLayoutWidth + 2 * Self.detailHorizontalInset
        let restingBarHostWidthFill = restingBarHost.widthAnchor.constraint(
            equalToConstant: maxHostWidth)
        restingBarHostWidthFill.priority = .defaultHigh

        // Dedicated full-pane host for the permission card. Added AFTER
        // `restingBarHost` so it sits **on top** in z-order (the card floats
        // over the bar). A plain `PermissionCardHostView` (regime-A:
        // `intrinsicContentSize = .zero` + the four-edge pin below) does NOT
        // publish its content's `fittingSize`, so it can't leak a size up into
        // the window's constraint solver and collapse the window. The layer
        // view's `hitTest` makes everything outside the mounted card
        // click-through so the transcript keeps its clicks + I-beam.
        permissionCardHost = PermissionCardHostView()
        permissionCardHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(permissionCardHost)

        // The once-built card coordinator (plan §4.0). It mounts / dismisses
        // the AppKit card inside the layer view; `present(sessionId:)` rebinds
        // it to the shown session in place.
        permissionCardController = PermissionCardController(
            layerView: permissionCardHost,
            sessionManager: context.sessionManager,
            syntaxEngine: context.syntaxEngine)

        NSLayoutConstraint.activate([
            topScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: view.topAnchor),
            topScrim.heightAnchor.constraint(equalToConstant: Self.topFadeScrimHeight),

            bottomScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomScrim.heightAnchor.constraint(equalToConstant: Self.bottomFadeScrimHeight),

            restingBarHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            restingBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            restingBarHost.widthAnchor.constraint(lessThanOrEqualToConstant: maxHostWidth),
            restingBarHost.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor),
            restingBarHostWidthFill,

            permissionCardHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            permissionCardHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            permissionCardHost.topAnchor.constraint(equalTo: view.topAnchor),
            permissionCardHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // No initial transcript attach here — the router owns that and
        // calls `present(sessionId:)` once this VC is mounted AND framed.
        // Self-attaching from `viewDidLoad` (before the fill constraints
        // sized the view) is exactly what forced the old deferred-attach
        // machinery; the router's "settle, then present" ordering removes
        // the need for it.
        //
        // No app-global observation installed here either: notification
        // activation and launch-failure alerts are owned by the stable
        // `DetailRouterViewController`, not self-observed per transcript VC
        // (that observation pinned this VC via a strong-`self`-across-await
        // re-arm and leaked it on every cross-kind round-trip).
    }

    /// Push the latest reported rects into the bottom scrim. Called
    /// every time the input bar fires a geometry callback — no Observation
    /// hop in between because the rects are local to this VC and there's no
    /// other consumer. The from-base is `inputBarController.view`, the exact
    /// view that anchors the bar (plan §4.1-2 / R6).
    private func applyScrimCutouts() {
        guard let anchor = inputBarController?.view else { return }
        bottomScrim.attachRect = bottomScrim.convert(lastAttachRect, from: anchor)
        bottomScrim.pillRect = bottomScrim.convert(lastPillRect, from: anchor)
    }

    // MARK: - Imperative presentation (driven by the router)

    /// Show `sessionId`'s transcript, or tear down to an empty chat
    /// backdrop when `nil` (the `.none` selection). The sole entry point
    /// the router calls — **synchronously**, after it has mounted and
    /// framed this VC, so the attach always runs against a settled
    /// frame. Replaces the old `model.selection`-observing path.
    ///
    /// `animated` carries the router's "fresh content" policy: a
    /// same-session-swap crossfade only runs on a first entry into the
    /// target session, never on warm re-entry. Defaults to `false` so the
    /// headless reentry merge gate (which drives `present` directly) stays
    /// on the synchronous path.
    func present(sessionId: String?, animated: Bool = false) {
        updateFocus(activeSessionId: sessionId)
        guard let sessionId else {
            swapCoordinator?.tearDownTranscript()
            // `.none` reproduces `ChatComposeStack.content`'s `.none → EmptyView`
            // collapse: the whole bar host disappears (no pill, no chrome row) on
            // the empty chat backdrop. HIDING the host — not just clearing its
            // model — is what matches the old `EmptyView`; `clearBinding()`
            // additionally resets text/attachments/completion + drops the
            // `Session` so a stale chrome row isn't staged behind the hidden host.
            // The host is un-hidden again on the next non-nil `present`.
            restingBarHost.isHidden = true
            inputBarController.clearBinding()
            // Synchronously dismiss any mounted card + drop the card's binding
            // (mirrors `inputBarController.clearBinding`, plan §4.0).
            permissionCardController.clearBinding()
            return
        }
        // Re-reveal the bar host (it may have been hidden by a prior `.none`).
        restingBarHost.isHidden = false
        // Resolve the `Session` ONCE (idempotent get-or-create) and hand the
        // SAME instance to BOTH the card controller AND the transcript
        // coordinator in the same source phase, so the card observes the exact
        // `Session` object the transcript is bound to (plan §4.0 stale-card
        // fix). The bar's `rebind(sessionId:)` re-resolves the same cached
        // instance internally — `prepareDraftSession` is idempotent.
        let session = context.sessionManager.prepareDraftSession(sessionId)
        // Rebind the bar in the SAME source phase as the transcript attach so
        // both overlays bind the same instance. The bar's constraints are
        // invariant across rebind, so the resting bar host frame is identical
        // before/after — `attachSession`'s layout pass stays bar-invariant.
        inputBarController.rebind(sessionId: sessionId)
        // Bind the card controller to the resolved session — cancels A's
        // observation, synchronously dismisses A's card, arms B's observation,
        // and runs the construction-time reconcile (plan §4.4-3).
        permissionCardController.rebind(for: session)
        transcriptSwapCoordinator().attachSession(sessionId, animated: animated)
    }

    /// `DetailRouterChild` — the router calls this right before it swaps
    /// this VC out on a cross-kind transition (`.transcript →
    /// .archive/.compose`). Tear the transcript down deterministically so
    /// the scroll view, sheet presenter, and `isRunning` task are released
    /// here rather than whenever ARC gets around to freeing the VC.
    func prepareForRemoval() {
        swapCoordinator?.tearDownTranscript()
        inputBarController?.prepareForRemoval()
        // Cancel the card's observation + synchronously dismiss any mounted
        // card (NO async work that would perturb an in-flight swap's disabled
        // CATransaction, plan §4.0 / R16). Idempotent.
        permissionCardController?.stop()
    }

    /// Lazily build (and cache) the transcript-swap coordinator. Deferred to
    /// first `present` so it can capture `view` after `loadView` has run. The
    /// `insertScroll` seam keeps the sibling-z knowledge here — the scroll
    /// goes **below `topScrim`**, i.e. beneath every overlay sibling
    /// (`bottomScrim` / `restingBarHost` / `permissionCardHost`), so the card
    /// is never covered and the transcript's clicks aren't swallowed (M5). The
    /// `onFirstScreenReady` seam keeps the first-screen latency log here, fed
    /// the `(attachStart, sessionId)` the coordinator captured.
    private func transcriptSwapCoordinator() -> TranscriptSwapCoordinator {
        if let swapCoordinator { return swapCoordinator }
        let coordinator = TranscriptSwapCoordinator(
            container: view,
            context: context,
            insertScroll: { [weak self] scroll in
                guard let self else { return }
                self.view.addSubview(scroll, positioned: .below, relativeTo: self.topScrim)
            },
            onFirstScreenReady: { attachStart, sessionId in
                let ms = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
                appLog(
                    .info, "TranscriptDetailVC",
                    "[firstScreen] sidebar→first view=\(String(format: "%.1f", ms))ms "
                        + "session=\(sessionId.prefix(8))…")
            }
        )
        swapCoordinator = coordinator
        return coordinator
    }

    /// Keep `Session.setFocused` in sync with the shown session so
    /// unread state clears on entry. (Draft `sessionId` allocation for
    /// New Session lives in `ComposeSessionViewController`.)
    private func updateFocus(activeSessionId: String?) {
        if let active = activeSessionId, let session = context.sessionManager.session(active) {
            session.setFocused(true)
        }
        for sid in context.sessionManager.records.map(\.sessionId) where sid != activeSessionId {
            context.sessionManager.existingSession(sid)?.setFocused(false)
        }
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit
    /// executor-hop (`swift_task_deinitOnExecutorImpl`) that aborts in the
    /// XCTest process — the macOS 26 libswift_Concurrency `TaskLocal`
    /// teardown bug the rest of the codebase already guards against (see
    /// `SessionRuntime.swift`). The transcript's `isRunning` task is now
    /// owned (and cancelled in its own `nonisolated deinit`) by
    /// `TranscriptSwapCoordinator`; releasing `swapCoordinator` here cascades
    /// into that. This VC keeps no `Task` of its own, so the body is empty —
    /// the `nonisolated` attribute is what matters.
    nonisolated deinit {}
}

// MARK: - Resting-bar container (regime-B host, AppKit)

/// The pure-AppKit replacement for the SwiftUI `NSHostingView<ChatComposeHostRoot>`
/// that used to host the chat resting bar (migration plan §4.0/§4.1). It stacks
/// the input bar pill on top of the chrome row, applying the chat bar's inner
/// width-cap + insets — the constraints translated verbatim from `ChatRestingBar`'s
/// `.frame(maxWidth: composeMaxWidth).padding(.horizontal, 20).padding(.bottom, 36)`.
///
/// Sizing is regime B: it publishes an **intrinsic height** (so the
/// `ChatSessionViewController`'s `[.intrinsicContentSize]`-equivalent contract
/// holds and the host shrinks to the bar's content) but **no intrinsic width**
/// (`noIntrinsicMetric`, so it never leaks `fittingSize.width` up into the
/// window's constraint solver and collapses the window, plan R1). The five
/// outer regime-B constraints (centerX / width<=cap / width==cap@high /
/// leading>= / bottom==) live on the VC; this view only owns its inner content
/// layout + its intrinsic height.
@MainActor
final class RestingBarContainerView: NSView {

    /// Vertical gap between the input pill and the chrome row below it. 10pt
    /// reads as a deliberate "second tier" without feeling detached from the
    /// bar (4pt fused the row with the pill stroke; 16pt let the transcript
    /// scrim creep between them). Re-homed here from the deleted SwiftUI
    /// `InputBarSessionChrome.barSpacing` — this container is the single
    /// consumer at every live call site (the chat resting bar, the
    /// draft-landing bar host, and the permission-session demo).
    static let barSpacing: CGFloat = 10

    private let barView: NSView
    private let chromeRow: NSView
    private let bottomInset: CGFloat
    private let barSpacing: CGFloat

    /// The inner content stack (pill + chrome row), capped + inset. The
    /// container's intrinsic height = this stack's fitting height + the bottom
    /// inset.
    private let innerContent = NSView()

    init(
        barView: InputBarView,
        chromeRow: NSView,
        innerMaxWidth: CGFloat,
        horizontalInset: CGFloat,
        bottomInset: CGFloat,
        barSpacing: CGFloat
    ) {
        self.barView = barView
        self.chromeRow = chromeRow
        self.bottomInset = bottomInset
        self.barSpacing = barSpacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // When the bar re-sums its height (text grow/shrink, attachment band,
        // completion popup), re-query our cached `intrinsicContentSize` (which
        // reads `innerContent.fittingSize.height`) so the intrinsic-size path
        // can't win with a stale value (R7). The `top==top` / `bottom==bottom`
        // constraint chain also pins our height, so this is belt-and-suspenders.
        barView.onIntrinsicHeightChanged = { [weak self] in
            self?.invalidateIntrinsicContentSize()
        }

        innerContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(innerContent)

        barView.translatesAutoresizingMaskIntoConstraints = false
        chromeRow.translatesAutoresizingMaskIntoConstraints = false
        innerContent.addSubview(barView)
        innerContent.addSubview(chromeRow)

        // Inner content: width-capped at `innerMaxWidth` (the SwiftUI
        // `.frame(maxWidth: composeMaxWidth)`), centered, with `horizontalInset`
        // on each side (`.padding(.horizontal, 20)`). The `<= cap @required`
        // never overflows; `== cap @high` fills up to the cap on a wide host but
        // yields to `leading >=` so the bar shrinks to fit a narrow host.
        let innerWidthFill = innerContent.widthAnchor.constraint(equalToConstant: innerMaxWidth)
        innerWidthFill.priority = .defaultHigh

        NSLayoutConstraint.activate([
            innerContent.centerXAnchor.constraint(equalTo: centerXAnchor),
            innerContent.widthAnchor.constraint(lessThanOrEqualToConstant: innerMaxWidth),
            innerContent.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: horizontalInset),
            innerWidthFill,
            // Top pins so the container's height is driven by the inner content
            // top → the container top; bottom pins at the bottom inset.
            innerContent.topAnchor.constraint(equalTo: topAnchor),
            innerContent.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -bottomInset),

            // Pill on top (its own content drives its height — regime B).
            barView.topAnchor.constraint(equalTo: innerContent.topAnchor),
            barView.leadingAnchor.constraint(equalTo: innerContent.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: innerContent.trailingAnchor),

            // Chrome row `barSpacing` below the pill, full width, fixed 22pt
            // height (the row's own intrinsic height), bottom of the stack.
            chromeRow.topAnchor.constraint(
                equalTo: barView.bottomAnchor, constant: barSpacing),
            chromeRow.leadingAnchor.constraint(equalTo: innerContent.leadingAnchor),
            chromeRow.trailingAnchor.constraint(equalTo: innerContent.trailingAnchor),
            chromeRow.bottomAnchor.constraint(equalTo: innerContent.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    /// Regime B: publish the content-driven HEIGHT (so the host shrinks to the
    /// bar, never fills the pane) but NO intrinsic width (so it never leaks
    /// `fittingSize.width` up into the window's constraint solver, plan R1). The
    /// height is the inner content's fitting height (which the bar's
    /// `invalidateIntrinsicContentSize` cascades into) plus the bottom inset.
    override var intrinsicContentSize: NSSize {
        let innerHeight = innerContent.fittingSize.height
        return NSSize(width: NSView.noIntrinsicMetric, height: innerHeight + bottomInset)
    }
}

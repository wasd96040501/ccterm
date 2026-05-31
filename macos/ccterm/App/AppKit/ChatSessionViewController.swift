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
/// Around the transcript we mount three full-bleed overlays, all
/// attached for the lifetime of the VC; their *contents* react to
/// `model.selection`:
/// - top scrim — `TranscriptScrimView` (AppKit, hitTest passthrough)
/// - bottom scrim — `TranscriptBottomScrimView` (AppKit, hitTest
///   passthrough, even-odd cutouts at the attach button + pill)
/// - input bar — `NSHostingView<AnyView>`. Its SwiftUI body switches on
///   `model.selection` via `ChatComposeStack.content(...)`: `.session(_)`
///   → chat resting bar, everything else → `EmptyView`. `.newSession` /
///   `.archive` / `.demo(_)` are routed away from this VC entirely by
///   `DetailRouterViewController` and never land here.
///
/// The host is bottom-anchored and takes only the bar (+ optional
/// permission card) intrinsic height, so the transcript scroll view
/// receives clicks in the scrim band above it.
@MainActor
final class ChatSessionViewController: NSViewController, DetailRouterChild {
    /// Coordinate-space identifier for SwiftUI `GeometryReader`/
    /// `PreferenceKey` callbacks that report the attach button +
    /// pill rects. Mirrors `RootView2.detailCoordSpace`.
    static let detailCoordSpace = "ChatSessionViewController.detail"
    /// Top fade band height. Sized to match the unified toolbar so the
    /// gradient fades in exactly the strip the toolbar visually covers.
    private static let topFadeScrimHeight: CGFloat = 52
    /// Bottom fade band height. Sized to match the input bar's top
    /// edge, so the gradient stops where the bar begins. Derived from
    /// `chatBottomInset` (36) + `InputBarSessionChrome` row (~22) +
    /// `InputBarSessionChrome.barSpacing` (10) + `InputBarView2` pill
    /// (32) = 100. Hardcoded — those constants don't change at runtime.
    private static let bottomFadeScrimHeight: CGFloat = 100
    static let composeMaxWidth: CGFloat = 512
    static let chatBottomInset: CGFloat = 36
    static let detailHorizontalInset: CGFloat = 20
    static let detailVerticalInset: CGFloat = 20

    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let notifications: NotificationService
    let searchEngine: SyntaxHighlightEngine
    let searchBus: TranscriptSearchBus
    let inputDraftStore: InputDraftStore

    /// The session currently driving the transcript, or nil for
    /// archive / demo branches.
    private var currentSession: Session?
    /// AppKit-native transcript scroll view. Re-created when the
    /// selected session's controller changes; nil for archive /
    /// demo branches.
    private var transcriptScroll: Transcript2ScrollView?
    /// AppKit-native sheet presenter for the transcript controller's
    /// `pendingUserBubbleSheet` / `pendingImagePreview` request
    /// fields. Replaces the SwiftUI `.sheet(item:)` bindings the old
    /// `NativeTranscript2View` carried. Re-instantiated per session
    /// attach (same lifecycle as `transcriptScroll`); nil for
    /// archive / demo branches (those VCs own their own presenter).
    private var transcriptSheetPresenter: Transcript2SheetPresenter?
    /// Full-bleed overlays. All three are added to `view` once and
    /// stay mounted for the lifetime of the VC. The scrims are pure
    /// AppKit (no `NSHostingView` so they don't register cursor rects
    /// that would shadow the transcript's I-beam); the input bar /
    /// compose card stays SwiftUI-hosted via a plain `NSHostingView`.
    private var topScrim: TranscriptTopScrimView!
    private var bottomScrim: TranscriptBottomScrimView!
    private var composeOrBarHost: NSHostingView<AnyView>!

    /// Latest attach / pill rects reported by the chat resting bar
    /// in `detailCoordSpace`. Used to drive `bottomScrim`'s cutouts.
    /// Local to this VC — there's no cross-VC consumer that would
    /// need to read these.
    private var lastAttachRect: CGRect = .zero
    private var lastPillRect: CGRect = .zero

    /// Sink for `session.isRunning` → `controller.setLoading(_:)`.
    /// Re-armed on every session swap.
    private var runningObservationTask: Task<Void, Never>?

    /// The outgoing transcript scroll view mid-crossfade, kept mounted
    /// (behind the incoming one) until the fade-out completes, paired with
    /// the session whose controller it must be dismantled against. `nil`
    /// when no same-session-swap crossfade is in flight. A new attach
    /// flushes it synchronously first (`finishTranscriptFadeOut`) — see the
    /// load-bearing note in `attachSession`.
    private var fadingOutTranscript: (scroll: Transcript2ScrollView, session: Session)?

    /// Crossfade duration for a session→session transcript swap. Matches
    /// `DetailRouterViewController.childCrossfadeDuration` so a same-kind
    /// switch and a cross-kind switch feel identical. Only the fade is
    /// non-atomic: the build → settle → bind → `scrollToTail` attach runs
    /// synchronously in the click's source phase (the §2.19 single-width
    /// contract is untouched — alpha is composite-only), then the opacity
    /// animation rides CoreAnimation's clock from `beforeWaiting`.
    private static let transcriptCrossfadeDuration: CFTimeInterval = 0.18

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

        composeOrBarHost = NSHostingView(rootView: AnyView(makeComposeOrBarStack()))
        composeOrBarHost.translatesAutoresizingMaskIntoConstraints = false
        // A plain `NSHostingView` claims every point in its bounds for
        // hit-testing, shadowing the transcript table below it. We keep its
        // bounds to just the bar: the HEIGHT is left to the content's own
        // intrinsic size (`.intrinsicContentSize`), so the host is only as
        // tall as the bar — multi-line input or a permission card grows it,
        // nothing else — and the transcript receives clicks everywhere above.
        composeOrBarHost.sizingOptions = [.intrinsicContentSize]
        view.addSubview(composeOrBarHost)

        // WIDTH is owned by AppKit, HEIGHT by the content (above):
        // - centerX  → the bar is horizontally centered in the pane.
        // - width <= maxHostWidth (required) caps it at the widest content it
        //   hosts — the permission card (`BlockStyle.maxLayoutWidth`) plus its
        //   horizontal padding — so the card is never clipped; the narrower
        //   input pill (`composeMaxWidth`) self-centers inside via its own frame.
        // - width == maxHostWidth @high fills up to that cap on a wide pane,
        //   but yields to `leading >=` on a pane narrower than the cap (detail
        //   can be as small as 680) so the bar shrinks to fit the pane instead
        //   of overflowing its edges.
        let maxHostWidth = BlockStyle.maxLayoutWidth + 2 * Self.detailHorizontalInset
        let composeOrBarHostWidthFill = composeOrBarHost.widthAnchor.constraint(
            equalToConstant: maxHostWidth)
        composeOrBarHostWidthFill.priority = .defaultHigh

        // Each scrim is sized to its visible band, anchored to its
        // edge. Cutout coordinates arrive in `composeOrBarHost`'s
        // SwiftUI coord space; `applyScrimCutouts` translates them
        // into the bottom scrim's local coord via `convert(_:from:)`.
        NSLayoutConstraint.activate([
            topScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: view.topAnchor),
            topScrim.heightAnchor.constraint(equalToConstant: Self.topFadeScrimHeight),

            bottomScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomScrim.heightAnchor.constraint(equalToConstant: Self.bottomFadeScrimHeight),

            composeOrBarHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            composeOrBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composeOrBarHost.widthAnchor.constraint(lessThanOrEqualToConstant: maxHostWidth),
            composeOrBarHost.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor),
            composeOrBarHostWidthFill,
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
    /// every time the chat resting bar fires a geometry callback —
    /// no Observation hop in between because the rects are local to
    /// this VC and there's no other consumer.
    private func applyScrimCutouts() {
        bottomScrim.attachRect = bottomScrim.convert(lastAttachRect, from: composeOrBarHost)
        bottomScrim.pillRect = bottomScrim.convert(lastPillRect, from: composeOrBarHost)
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
            tearDownTranscript()
            return
        }
        attachSession(sessionId, animated: animated)
    }

    /// `DetailRouterChild` — the router calls this right before it swaps
    /// this VC out on a cross-kind transition (`.transcript →
    /// .archive/.compose`). Tear the transcript down deterministically so
    /// the scroll view, sheet presenter, and `isRunning` task are released
    /// here rather than whenever ARC gets around to freeing the VC.
    func prepareForRemoval() {
        tearDownTranscript()
    }

    /// Keep `Session.setFocused` in sync with the shown session so
    /// unread state clears on entry. (Draft `sessionId` allocation for
    /// New Session lives in `ComposeSessionViewController`.)
    private func updateFocus(activeSessionId: String?) {
        if let active = activeSessionId, let session = sessionManager.session(active) {
            session.setFocused(true)
        }
        for sid in sessionManager.records.map(\.sessionId) where sid != activeSessionId {
            sessionManager.existingSession(sid)?.setFocused(false)
        }
    }

    // MARK: - Transcript mount

    private func attachSession(_ sessionId: String, animated: Bool = false) {
        // Contract: the router only calls `present` on a mounted, framed
        // VC, so the geometry-sensitive attach below (pin scroll view →
        // `layoutSubtreeIfNeeded` settles the table width → `scrollToTail`
        // anchors the clip) always has a real frame to work against.
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            assertionFailure("attachSession called before the host view was framed")
            return
        }

        let session = sessionManager.prepareDraftSession(sessionId)
        if currentSession?.sessionId == sessionId, transcriptScroll != nil {
            return
        }

        // Flush a still-running transcript crossfade synchronously before
        // building the incoming scroll. **Load-bearing for A→B→A re-entry:**
        // `TranscriptScrollViewFactory.dismantle` calls a blanket
        // `removeObserver(coordinator)`, so if the outgoing scroll for the
        // SAME session is still parked when we re-enter it, deferring its
        // teardown would rip the frameDidChange / liveScroll observers off
        // the freshly-bound incoming scroll (same coordinator). Tearing the
        // parked scroll down here — before `bindData` below re-registers
        // them — keeps the incoming scroll's observers intact. A rapid
        // A→B→C collapses the same way: B snaps out as C builds.
        finishTranscriptFadeOut()

        // Stopwatch for "sidebar click → first rendered screen". Cold attaches
        // paint blank for the first tick (block building is off-main), so this
        // measures the gap the cold-load first-screen edge closes. Reported in
        // the `onFirstScreenReady` callback wired just before `loadHistory`.
        let attachStart = CFAbsoluteTimeGetCurrent()

        // Atomic structural swap: build, mount, bind, and anchor the
        // INCOMING transcript — all inside one disabled-animation
        // transaction — then either drop the OUTGOING one synchronously
        // (no window / cold start) or crossfade it out (the common
        // session→session switch). Building the new scroll on top of the
        // old and never removing the old before the new is live means the
        // user never sees an empty pane.
        let outgoingScroll = transcriptScroll
        let outgoingSession = currentSession
        // Crossfade only when the router asked for it (a first entry into
        // this session — never a warm re-entry), there's an outgoing
        // transcript, AND we're on a live window. Without a window (the
        // §2.19 reentry merge gate, any headless attach) the swap stays
        // synchronous — identical to the pre-animation behavior, so the
        // probe sees the same writes.
        let animateSwap = animated && outgoingScroll != nil && view.window != nil

        // Explicit begin/commit (not `defer`): the crossfade below must run
        // OUTSIDE this disabled-animation transaction, or the opacity
        // animation would be suppressed by `setDisableActions(true)`. There
        // are no early returns between here and the commit.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scroll = TranscriptScrollViewFactory.make(controller: session.controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Start the incoming scroll transparent when we're going to fade it
        // in. Set inside the disabled transaction so the 0 itself doesn't
        // animate; the fade up to 1 is a separate group after commit.
        if animateSwap {
            scroll.wantsLayer = true
            scroll.alphaValue = 0
        }
        // Insert just below the top scrim — i.e. in front of the still-mounted
        // outgoing scroll view — so the incoming transcript covers it (or,
        // when animating, crossfades over it).
        view.addSubview(scroll, positioned: .below, relativeTo: topScrim)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Pull layout into the current call stack so the table reaches
        // its real width before we bind the dataSource — with the bind
        // deferred until now, AppKit has no rows to query and the
        // autolayout pass settles without any `heightOfRow` queries at
        // transient widths. The downstream `scrollToTail` and history
        // load can then run in the same source phase.
        view.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: session.controller)
        transcriptScroll = scroll
        currentSession = session

        // Re-attach scroll: bridge-accumulated blocks from a previous
        // mount land here with no setHistory follow-up (loadHistory is
        // idempotent and short-circuits). Anchor to the tail synchronously
        // now that the table has real width.
        //
        // Resident reentry telemetry: the first tile `scrollToTail` forces
        // queries `heightOfRow` for every row, and cache *misses* (blocks the
        // bridge appended while this session was detached, or a width change
        // since it was last displayed) recompute their `RowLayout` on the main
        // thread right here. We read the coordinator's monotonic compute
        // counter as a delta around this one tile so the cost is logged ONCE
        // per attach (session switches are user-paced — not a hot path); the
        // per-row typeset itself is never logged.
        let layoutComputesBeforeTile = session.controller.mainThreadLayoutComputes
        let reentryTileStart = CFAbsoluteTimeGetCurrent()
        session.controller.scrollToTail()
        let reentryTileMs = (CFAbsoluteTimeGetCurrent() - reentryTileStart) * 1000
        let reentryTypeset =
            session.controller.mainThreadLayoutComputes &- layoutComputesBeforeTile

        // Attach syntax engine (idempotent).
        session.controller.attachSyntaxEngine(searchEngine)

        // Sheet presenter is per-attach: it captures `view` (for
        // `window`) and the session's controller. The presenter
        // observes `pendingUserBubbleSheet` / `pendingImagePreview`
        // and presents AppKit-native sheets via
        // `view.window?.beginSheet`. Replaces the SwiftUI
        // `.sheet(item:)` bindings the old `NativeTranscript2View`
        // carried. Stop the outgoing one first.
        transcriptSheetPresenter?.stop()
        transcriptSheetPresenter = Transcript2SheetPresenter(
            controller: session.controller, hostView: view)

        // Kick history load + initial running pill sync (mirrors
        // `ChatHistoryView.task(id: sessionId)`).
        appLog(
            .info, "TranscriptDetailVC",
            "[history] attach session=\(sessionId.prefix(8))… "
                + "loadState=\(String(describing: session.historyLoadState)) "
                + "msgCount=\(session.messages.count) "
                + "blockCount=\(session.controller.blockCount) "
                + "reentryTypeset=\(reentryTypeset) "
                + "reentryTile=\(String(format: "%.1f", reentryTileMs))ms")
        // Log the cold-load first-screen latency once it lands. Capture only
        // the sessionId string + start time (no `self` / `session`) so the
        // closure stored on the controller can't form a retain cycle. On a warm
        // re-entry the edge already fired during the original cold load, so the
        // latched callback never re-fires — no spurious log.
        session.controller.onFirstScreenReady = {
            let ms = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
            appLog(
                .info, "TranscriptDetailVC",
                "[firstScreen] sidebar→first view=\(String(format: "%.1f", ms))ms "
                    + "session=\(sessionId.prefix(8))…")
        }
        session.loadHistory()
        session.controller.setLoading(session.isRunning)
        // turnUsage rides the imperative channel: push the current value once on
        // mount, then let `onTurnUsageChange` drive live updates (the runtime
        // fires it synchronously at each write — no observation pull).
        session.controller.setTurnUsage(session.turnUsage)
        session.onTurnUsageChange = { [weak self, weak session] usage in
            guard let self, let session, self.currentSession === session else { return }
            session.controller.setTurnUsage(usage)
        }

        // Re-arm the `isRunning` → controller sink (cancels the old).
        startRunningObservation(for: session)

        // Synchronous path: drop the outgoing transcript last, now that the
        // incoming one is live and on top — no blank frame in between. Stays
        // inside the disabled-animation transaction so the teardown doesn't
        // flicker. The animated path leaves the outgoing scroll mounted and
        // hands it to the crossfade below.
        if !animateSwap, let outgoingScroll, let outgoingSession {
            TranscriptScrollViewFactory.dismantle(
                outgoingScroll, controller: outgoingSession.controller)
            outgoingScroll.removeFromSuperview()
        }

        CATransaction.commit()
        NSAnimationContext.endGrouping()

        // Cosmetic crossfade, OUTSIDE the disabled transaction so it can
        // actually animate. The incoming content is already live (typeset,
        // bound, scrolled to tail above), so the first composited fade frame
        // shows real content over the outgoing transcript.
        if animateSwap, let outgoingScroll, let outgoingSession {
            crossfadeTranscriptSwap(
                incoming: scroll, outgoing: outgoingScroll, outgoingSession: outgoingSession)
        }
    }

    /// Fade the incoming transcript in and the outgoing one out together,
    /// then dismantle the outgoing scroll on completion. Parks the outgoing
    /// scroll in `fadingOutTranscript` so a follow-up attach can flush it
    /// synchronously (see `attachSession`'s load-bearing note on the
    /// blanket `removeObserver`).
    private func crossfadeTranscriptSwap(
        incoming: Transcript2ScrollView,
        outgoing: Transcript2ScrollView,
        outgoingSession: Session
    ) {
        outgoing.wantsLayer = true
        fadingOutTranscript = (outgoing, outgoingSession)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.transcriptCrossfadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.finishTranscriptFadeOut(expected: outgoing)
        }
    }

    /// Tear down the parked outgoing transcript scroll. Idempotent and
    /// called from three places: the crossfade completion (with `expected`
    /// set), synchronously at the head of a new attach to flush an in-flight
    /// fade, and from `tearDownTranscript`. The `expected` guard makes a
    /// late completion for an already-flushed scroll a no-op.
    private func finishTranscriptFadeOut(expected: Transcript2ScrollView? = nil) {
        guard let parked = fadingOutTranscript else { return }
        if let expected, expected !== parked.scroll { return }
        fadingOutTranscript = nil
        TranscriptScrollViewFactory.dismantle(
            parked.scroll, controller: parked.session.controller)
        parked.scroll.removeFromSuperview()
    }

    private func tearDownTranscript() {
        // Drop a parked outgoing scroll first — otherwise tearing down only
        // the current scroll would leave a mid-fade ghost mounted when the
        // router swaps this VC out cross-kind during a session→session fade.
        finishTranscriptFadeOut()
        if let scroll = transcriptScroll, let session = currentSession {
            TranscriptScrollViewFactory.dismantle(scroll, controller: session.controller)
            scroll.removeFromSuperview()
        }
        transcriptScroll = nil
        currentSession = nil
        transcriptSheetPresenter?.stop()
        transcriptSheetPresenter = nil
        runningObservationTask?.cancel()
        runningObservationTask = nil
    }

    private func startRunningObservation(for session: Session) {
        runningObservationTask?.cancel()
        runningObservationTask = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled {
                guard let session else { return }
                await withCheckedContinuation { cont in
                    withObservationTracking {
                        _ = session.isRunning
                    } onChange: {
                        Task { @MainActor in cont.resume() }
                    }
                }
                guard let self, self.currentSession === session else { return }
                session.controller.setLoading(session.isRunning)
            }
        }
    }

    // MARK: - SwiftUI overlay builders

    private func makeComposeOrBarStack() -> some View {
        ChatComposeStack(
            model: model,
            onSubmit: { [weak self] submission, sessionId in
                guard let self else { return }
                submitSessionInput(
                    submission,
                    sessionId: sessionId,
                    sessionManager: self.sessionManager,
                    recentProjects: self.recentProjects,
                    model: self.model)
            },
            onAttachRect: { [weak self] rect in
                guard let self else { return }
                self.lastAttachRect = rect
                self.applyScrimCutouts()
            },
            onPillRect: { [weak self] rect in
                guard let self else { return }
                self.lastPillRect = rect
                self.applyScrimCutouts()
            },
            onBuiltinCommand: { [weak self] command, sessionId in
                guard let self else { return }
                runBuiltinSlashCommand(
                    command,
                    currentSessionId: sessionId,
                    sessionManager: self.sessionManager,
                    model: self.model)
            }
        )
        .environment(sessionManager)
        .environment(recentProjects)
        .environment(inputDraftStore)
        .environment(\.syntaxEngine, searchEngine)
        .environment(searchBus)
        .environment(notifications)
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit
    /// executor-hop (`swift_task_deinitOnExecutorImpl`) that aborts in the
    /// XCTest process — the macOS 26 libswift_Concurrency `TaskLocal`
    /// teardown bug the rest of the codebase already guards against (see
    /// `SessionRuntime.swift`). Cancelling a `Task` needs no isolation.
    nonisolated deinit {
        runningObservationTask?.cancel()
    }
}

// MARK: - SwiftUI overlay subviews

/// Chat-mode resting input bar (or nothing). The always-mounted bar
/// host of `ChatSessionViewController` renders this; it reads state from
/// the shared `MainSelectionModel` so the AppKit VC can drive selection
/// flips imperatively from outside SwiftUI.
///
/// New Session's compose card is NOT here — it has its own
/// `ComposeSessionViewController` / `ComposeSessionView`. This stack only
/// ever shows the chat resting bar for `.session(_)`, and `EmptyView`
/// for every other selection.
struct ChatComposeStack: View {
    @Bindable var model: MainSelectionModel
    let onSubmit: (InputBarView2.Submission, String) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void
    /// Builtin slash command dispatcher, carrying the bar's live session
    /// id so `/new` / `/clear` can seed the new draft from it.
    let onBuiltinCommand: (BuiltinSlashCommand, String) -> Void

    /// Routing decision for this overlay. Static + pure so the
    /// "which selection shows what input chrome" invariant is
    /// directly unit-testable — see `ChatComposeStackRoutingTests`.
    /// Only `.session(_)` renders a bar; everything else collapses to
    /// `.none`, which is what keeps the input bar from rendering on top
    /// of (and intercepting clicks on) pages where this VC might be
    /// mounted. `.newSession` is routed to `ComposeSessionViewController`
    /// by the router and never reaches this stack, but it still maps to
    /// `.none` here as belt-and-suspenders.
    enum Content: Equatable {
        case none
        case chat(sessionId: String)
    }

    static func content(for selection: MainSelection, draftSessionId: String?) -> Content {
        switch selection {
        case .none, .newSession, .archive:
            return .none
        #if DEBUG
        case .demo:
            return .none
        #endif
        case .session(let sid):
            return .chat(sessionId: sid)
        }
    }

    var body: some View {
        let content = Self.content(for: model.selection, draftSessionId: model.draftSessionId)
        ZStack {
            switch content {
            case .none:
                EmptyView()
            case .chat(let sid):
                // `.id(sid)` resets `InputBarView2`'s `@State`
                // (text, attachments, focus, completion) on every
                // session switch. Without it, the bar's local state
                // persists across sessions — the bar's `.task(id:
                // draftKey)` restore is gated on `text.isEmpty &&
                // attachments.isEmpty`, so a non-empty bar would
                // both display the previous session's body and
                // overwrite the new session's draft on the next
                // keystroke. Pre-#195 this reset came for free from
                // `.id(sid)` on `ChatHistoryView`, which used to
                // bracket the overlay-hosted input bar.
                ChatRestingBar(
                    sessionId: sid,
                    draftKey: sid,
                    onSubmit: { submission in onSubmit(submission, sid) },
                    onAttachRect: onAttachRect,
                    onPillRect: onPillRect,
                    onBuiltinCommand: { command in onBuiltinCommand(command, sid) }
                )
                .id(sid)
            }
        }
        // Fill the width the AppKit host hands us — the host is centered and
        // width-capped (at the widest content) by `ChatSessionViewController`.
        // Height is left to the content's own intrinsic size, which the host
        // reads via its `.intrinsicContentSize` sizing option. The pill and
        // permission card self-limit and center inside this width via their
        // own frames.
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: ChatSessionViewController.detailCoordSpace)
    }
}

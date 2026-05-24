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
final class ChatSessionViewController: NSViewController {
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
    private var topScrim: TranscriptScrimView!
    private var bottomScrim: TranscriptBottomScrimView!
    private var composeOrBarHost: NSHostingView<AnyView>!

    /// Fixes the host's height to the bar's reported content height
    /// (driven by the SwiftUI body's `onContentHeight` callback),
    /// bottom-anchored. Always active — the host only ever renders the
    /// chat resting bar (or nothing), never a full-bleed configurator,
    /// so it never needs to grow past the bar.
    private var composeOrBarHostHeightConstraint: NSLayoutConstraint!

    /// Latest attach / pill rects reported by the chat resting bar
    /// in `detailCoordSpace`. Used to drive `bottomScrim`'s cutouts.
    /// Local to this VC — there's no cross-VC consumer that would
    /// need to read these.
    private var lastAttachRect: CGRect = .zero
    private var lastPillRect: CGRect = .zero

    /// Sink for `session.isRunning` → `controller.setLoading(_:)`.
    /// Re-armed on every session swap.
    private var runningObservationTask: Task<Void, Never>?
    /// Sink for the launch-failure alert.
    private var launchFailureObservationTask: Task<Void, Never>?

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
        // The NSWindow paints `windowBackgroundColor` behind the
        // transcript scroll view (which sets `drawsBackground = false`)
        // — we just need a plain container view here.
        view = NSView()

        topScrim = TranscriptScrimView(edge: .top, bandHeight: Self.topFadeScrimHeight)
        topScrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topScrim)

        bottomScrim = TranscriptBottomScrimView(bandHeight: Self.bottomFadeScrimHeight)
        bottomScrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomScrim)

        composeOrBarHost = NSHostingView(rootView: AnyView(makeComposeOrBarStack()))
        composeOrBarHost.translatesAutoresizingMaskIntoConstraints = false
        // A plain `NSHostingView` claims EVERY point in its bounds for
        // hit-testing, shadowing whatever AppKit view sits below — here
        // the transcript table. So the host must cover ONLY the bar at
        // the bottom, or it eats the transcript's selection / hover-gutter
        // mouse events everywhere it overlaps.
        //
        // Drive the height EXPLICITLY rather than leaning on the host's
        // intrinsic size:
        // - `sizingOptions = []` stops the host from publishing any
        //   intrinsic height. The bottom-anchored `.intrinsicContentSize`
        //   variant leaked a *required* height up through the split into
        //   the window's constraint layout and collapsed the window
        //   (`_changeWindowFrameFromConstraintsIfNecessary`); an empty
        //   set severs that path entirely.
        // - `composeOrBarHostHeightConstraint`'s constant is set from the
        //   SwiftUI body's reported content height (`onContentHeight`),
        //   so the host tracks the bar exactly — multi-line input or a
        //   permission card grows it, nothing else, and it never covers
        //   more of the transcript than the bar actually needs.
        composeOrBarHost.sizingOptions = []
        view.addSubview(composeOrBarHost)

        // Bottom + leading + trailing pinned; height fixed to the bar's
        // measured content height (set via `onContentHeight`). The host
        // is never full-bleed — compose has its own VC now — so this
        // height constraint is simply always active.
        composeOrBarHostHeightConstraint =
            composeOrBarHost.heightAnchor.constraint(equalToConstant: 0)

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

            composeOrBarHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composeOrBarHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composeOrBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composeOrBarHostHeightConstraint,
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
        installObservations()
    }

    // MARK: - Observation

    private func installObservations() {
        startLaunchFailureObservation()
    }

    /// Push the latest reported rects into the bottom scrim. Called
    /// every time the chat resting bar fires a geometry callback —
    /// no Observation hop in between because the rects are local to
    /// this VC and there's no other consumer.
    private func applyScrimCutouts() {
        bottomScrim.attachRect = bottomScrim.convert(lastAttachRect, from: composeOrBarHost)
        bottomScrim.pillRect = bottomScrim.convert(lastPillRect, from: composeOrBarHost)
    }

    private func startLaunchFailureObservation() {
        launchFailureObservationTask?.cancel()
        launchFailureObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.sessionManager.lastLaunchFailure
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.presentLaunchFailureAlertIfNeeded()
            self.startLaunchFailureObservation()
        }
    }

    private func presentLaunchFailureAlertIfNeeded() {
        guard let failure = sessionManager.lastLaunchFailure else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Failed to launch CLI")
        alert.informativeText = failure.message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                self?.sessionManager.clearLaunchFailure()
            }
        } else {
            alert.runModal()
            sessionManager.clearLaunchFailure()
        }
    }

    // MARK: - Imperative presentation (driven by the router)

    /// Show `sessionId`'s transcript, or tear down to an empty chat
    /// backdrop when `nil` (the `.none` selection). The sole entry point
    /// the router calls — **synchronously**, after it has mounted and
    /// framed this VC, so the attach always runs against a settled
    /// frame. Replaces the old `model.selection`-observing path.
    func present(sessionId: String?) {
        updateFocus(activeSessionId: sessionId)
        guard let sessionId else {
            tearDownTranscript()
            return
        }
        attachSession(sessionId)
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

    private func attachSession(_ sessionId: String) {
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
        // Stopwatch for "sidebar click → first rendered screen". Cold attaches
        // paint blank for the first tick (block building is off-main), so this
        // measures the gap the cold-load first-screen edge closes. Reported in
        // the `onFirstScreenReady` callback wired just before `loadHistory`.
        let attachStart = CFAbsoluteTimeGetCurrent()

        // Atomic swap: build, mount, bind, and anchor the INCOMING
        // transcript, then tear down the OUTGOING one — all inside one
        // disabled-animation transaction. Removing the old scroll view
        // first (the previous shape) flashed a blank pane for at least
        // one frame; building the new one on top of the old and dropping
        // the old last means the user never sees an empty transcript.
        let outgoingScroll = transcriptScroll
        let outgoingSession = currentSession

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        let scroll = TranscriptScrollViewFactory.make(controller: session.controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Insert just below the top scrim — i.e. in front of the still-mounted
        // outgoing scroll view — so the incoming transcript fully covers it
        // until we drop the old one at the end of this tick.
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

        // Re-arm the `isRunning` → `setLoading` sink (cancels the old).
        startRunningObservation(for: session)

        // Drop the outgoing transcript last, now that the incoming one is
        // live and on top — no blank frame in between.
        if let outgoingScroll, let outgoingSession {
            TranscriptScrollViewFactory.dismantle(
                outgoingScroll, controller: outgoingSession.controller)
            outgoingScroll.removeFromSuperview()
        }
    }

    private func tearDownTranscript() {
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
            onContentHeight: { [weak self] height in
                // Chat bar height → host height constraint.
                self?.composeOrBarHostHeightConstraint.constant = height
            }
        )
        .environment(sessionManager)
        .environment(recentProjects)
        .environment(inputDraftStore)
        .environment(\.syntaxEngine, searchEngine)
        .environment(searchBus)
        .environment(notifications)
    }

    deinit {
        runningObservationTask?.cancel()
        launchFailureObservationTask?.cancel()
    }
}

// MARK: - SwiftUI overlay subviews

/// Carries `ChatComposeStack`'s measured natural height out to the
/// AppKit host so it can size the chat-mode bar exactly.
private struct BarContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
    /// Reports the body's natural height to the host so the
    /// `composeOrBarHostHeightConstraint` can size to exactly the bar.
    let onContentHeight: (CGFloat) -> Void

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
                    onPillRect: onPillRect
                )
                // Pin to the bar's natural height so the measured
                // value below is the bar's own footprint, never the
                // (possibly zero / stale) height the host proposes.
                .fixedSize(horizontal: false, vertical: true)
                .id(sid)
            }
        }
        // Width-infinite always (the host is leading/trailing-pinned).
        // Height is intentionally NOT `.infinity`: the host is
        // bottom-anchored to exactly the bar's height, reported to AppKit
        // via `onContentHeight` below.
        .frame(maxWidth: .infinity)
        .background {
            // Measure the body's natural height without joining the
            // layout, and feed it to the host height constraint. `.none`
            // measures the empty body as 0, collapsing the host so the
            // transcript receives clicks everywhere.
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BarContentHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(BarContentHeightKey.self) { height in
            onContentHeight(height)
        }
        .coordinateSpace(name: ChatSessionViewController.detailCoordSpace)
    }
}

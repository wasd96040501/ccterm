import AppKit
import Combine
import Observation
import SwiftUI

/// Child VC the `DetailRouterViewController` mounts for chat-bearing
/// selections (`.session` / `.newSession` / `.none`). Owns the transcript
/// `Transcript2ScrollView` directly — created in `loadView()` so the
/// table's mount + `frameDidChange` cascade lives in AppKit's source
/// phase, not in SwiftUI's commit pass (the whole point of #195).
///
/// Around the transcript we mount three full-bleed overlays, all
/// attached for the lifetime of the VC; their *contents* react to
/// `model.selection`:
/// - top scrim — `TranscriptScrimView` (AppKit, hitTest passthrough)
/// - bottom scrim — `TranscriptBottomScrimView` (AppKit, hitTest
///   passthrough, even-odd cutouts at the attach button + pill)
/// - input bar / compose configurator — `NSHostingView<AnyView>`.
///   Its SwiftUI body switches on `model.selection` via
///   `TranscriptDetailComposeStack.content(...)`: `.newSession` →
///   compose card, `.session(_)` → chat resting bar, `.none` →
///   `EmptyView`. `.archive` and `.demo(_)` are routed away from
///   this VC entirely by `DetailRouterViewController` and never
///   land here, so the host always renders a chat-flavored body —
///   no need for any of the hit-test passthrough gymnastics earlier
///   commits on this PR were forced to ship.
///
/// In chat mode the host is bottom-anchored and takes only the bar
/// (+ optional permission card) intrinsic height, so the transcript
/// scroll view receives clicks in the scrim band above. In compose
/// mode the host's top constraint is activated so the configurator
/// card has the full pane to lay out in.
@MainActor
final class TranscriptDetailViewController: NSViewController {
    /// Coordinate-space identifier for SwiftUI `GeometryReader`/
    /// `PreferenceKey` callbacks that report the attach button +
    /// pill rects. Mirrors `RootView2.detailCoordSpace`.
    static let detailCoordSpace = "TranscriptDetailViewController.detail"
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

    /// Sink for `model.attachRect` / `pillRect` → `bottomScrim` cutout
    /// path. Re-arms on every fire.
    /// Toggled active in compose mode to pin the host's top to
    /// `view.topAnchor` (full-bleed). Inactive in chat / .none modes
    /// — the host then sizes to its SwiftUI body's intrinsic height,
    /// anchored at the bottom. This is what lets clicks in the
    /// transcript's scrim band reach the table rather than getting
    /// swallowed by a transparent overlay.
    private var composeOrBarHostTopConstraint: NSLayoutConstraint!

    /// Latest attach / pill rects reported by the chat resting bar
    /// in `detailCoordSpace`. Used to drive `bottomScrim`'s cutouts.
    /// Local to this VC — there's no cross-VC consumer that would
    /// need to read these.
    private var lastAttachRect: CGRect = .zero
    private var lastPillRect: CGRect = .zero

    /// Sink for `session.isRunning` → `controller.setLoading(_:)`.
    /// Re-armed on every session swap.
    private var runningObservationTask: Task<Void, Never>?
    /// Sink for the sidebar selection + draft fields. Re-arms after
    /// each fire (one-shot `withObservationTracking` semantics).
    private var selectionObservationTask: Task<Void, Never>?
    /// Sink for the launch-failure alert.
    private var launchFailureObservationTask: Task<Void, Never>?
    /// Sink for `notifications.pendingActivationSessionId`.
    private var pendingActivationObservationTask: Task<Void, Never>?

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
        view.addSubview(composeOrBarHost)

        // Bottom + leading + trailing always pinned. The top
        // constraint is created here but only activated in compose
        // mode (see `updateComposeHostShape`) — chat mode lets the
        // host take SwiftUI's intrinsic height anchored at the
        // bottom, so the scrim band above the bar stays clickable.
        composeOrBarHostTopConstraint =
            composeOrBarHost.topAnchor.constraint(equalTo: view.topAnchor)

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
        ])
    }

    /// Activate / deactivate the host's top constraint to match the
    /// current selection. Compose mode wants the configurator full-
    /// bleed; chat mode wants only the bar at the bottom; `.none`
    /// can use either (the body is `EmptyView` so it shrinks to 0
    /// regardless).
    private func updateComposeHostShape() {
        let shouldPinTop = model.isComposeMode
        if composeOrBarHostTopConstraint.isActive != shouldPinTop {
            composeOrBarHostTopConstraint.isActive = shouldPinTop
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Run the initial selection handler so the lazy
        // `draftSessionId` allocation + focus tracking + side-branch
        // mount happens for the model's initial value. Mirrors
        // `RootView2`'s `.task(id: selection)` which fired once
        // on mount in addition to firing on every change.
        handleSelectionChanged()
        installObservations()
        // Notification subsystem bootstrap, kicked once per
        // main-window mount. `bootstrap()` guards against re-entry.
        notifications.bootstrap()
    }

    // MARK: - Observation

    private func installObservations() {
        startSelectionObservation()
        startLaunchFailureObservation()
        startPendingActivationObservation()
    }

    /// Push the latest reported rects into the bottom scrim. Called
    /// every time the chat resting bar fires a geometry callback —
    /// no Observation hop in between because the rects are local to
    /// this VC and there's no other consumer.
    private func applyScrimCutouts() {
        bottomScrim.attachRect = bottomScrim.convert(lastAttachRect, from: composeOrBarHost)
        bottomScrim.pillRect = bottomScrim.convert(lastPillRect, from: composeOrBarHost)
    }

    private func startSelectionObservation() {
        selectionObservationTask?.cancel()
        selectionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // One-shot Observation tracking — re-arm via tail
            // recursion through `startSelectionObservation` once it
            // fires. We touch every field we care about inside the
            // tracking closure so re-arm happens on any change.
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.model.selection
                    _ = self.model.draftSessionId
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.handleSelectionChanged()
            self.startSelectionObservation()
        }
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

    private func startPendingActivationObservation() {
        pendingActivationObservationTask?.cancel()
        pendingActivationObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.notifications.pendingActivationSessionId
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            if let sid = self.notifications.pendingActivationSessionId {
                self.model.selection = .session(sid)
                self.notifications.clearPendingActivation()
            }
            self.startPendingActivationObservation()
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

    private func handleSelectionChanged() {
        // Lazy-allocate draftSessionId on entering New Session, and
        // seed the draft's `cwd` / `originPath` synchronously here so
        // `session.cwd` is non-nil by the time `NewSessionConfigurator`
        // and the input bar's completion context first read it.
        // `useWorktree` / `sourceBranch` are left to
        // `NewSessionConfigurator.applyProbeBindings(...)` to fill in
        // off the git probe.
        if model.selection == .newSession, model.draftSessionId == nil {
            let sid = UUID().uuidString.lowercased()
            model.draftSessionId = sid
            if let cwd = recentProjects.lastLaunchedPath,
                let draft = sessionManager.prepareDraftSession(sid).draft
            {
                draft.setCwd(cwd)
                draft.setOriginPath(cwd)
            }
        }

        // Focus tracking — keep `Session.setFocused` in sync with the
        // selection so unread state clears when the user enters a
        // session.
        let activeSid = model.effectiveSessionId
        if let active = activeSid, let session = sessionManager.session(active) {
            session.setFocused(true)
        }
        for sid in sessionManager.records.map(\.sessionId)
        where sid != activeSid {
            sessionManager.existingSession(sid)?.setFocused(false)
        }

        updateComposeHostShape()
        rebuildBackingContent()
    }

    // MARK: - Backing content rebuild

    private func rebuildBackingContent() {
        guard let active = model.effectiveSessionId else {
            tearDownTranscript()
            return
        }
        attachSession(active)
    }

    // MARK: - Transcript mount

    private func attachSession(_ sessionId: String) {
        let session = sessionManager.prepareDraftSession(sessionId)
        if currentSession?.sessionId == sessionId, transcriptScroll != nil {
            return
        }
        tearDownTranscript()

        let scroll = TranscriptScrollViewFactory.make(controller: session.controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
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
        session.controller.scrollToTail()

        // Attach syntax engine (idempotent).
        session.controller.attachSyntaxEngine(searchEngine)

        // Sheet presenter is per-attach: it captures `view` (for
        // `window`) and the session's controller. The presenter
        // observes `pendingUserBubbleSheet` / `pendingImagePreview`
        // and presents AppKit-native sheets via
        // `view.window?.beginSheet`. Replaces the SwiftUI
        // `.sheet(item:)` bindings the old `NativeTranscript2View`
        // carried.
        transcriptSheetPresenter = Transcript2SheetPresenter(
            controller: session.controller, hostView: view)

        // Kick history load + initial running pill sync (mirrors
        // `ChatHistoryView.task(id: sessionId)`).
        appLog(
            .info, "TranscriptDetailVC",
            "[history] attach session=\(sessionId.prefix(8))… "
                + "loadState=\(String(describing: session.historyLoadState)) "
                + "msgCount=\(session.messages.count) "
                + "blockCount=\(session.controller.blockCount)")
        session.loadHistory()
        session.controller.setLoading(session.isRunning)

        // Re-arm the `isRunning` → `setLoading` sink.
        startRunningObservation(for: session)
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
        TranscriptDetailComposeStack(
            model: model,
            onSubmit: { [weak self] submission, sessionId in
                self?.submit(submission, sessionId: sessionId)
            },
            onResumeSession: { [weak self] resumeSid in
                guard let self else { return }
                self.model.selection = .session(resumeSid)
                self.model.draftSessionId = nil
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
            }
        )
        .environment(sessionManager)
        .environment(recentProjects)
        .environment(inputDraftStore)
        .environment(\.syntaxEngine, searchEngine)
        .environment(searchBus)
        .environment(notifications)
        // Without `.ignoresSafeArea()`, `NSHostingView` would forward
        // a toolbar-sized top safe-area inset to SwiftUI in compose
        // mode (when the host is full-bleed); the rects reported in
        // `detailCoordSpace` would then sit in an inset coord space
        // while `bottomScrim` (full-bleed AppKit) renders in
        // `view.bounds`, and the cutouts would land `toolbarHeight`
        // pixels too high. In chat mode the host is bottom-anchored,
        // doesn't intersect the top safe area, so this is a no-op
        // there — kept on for the compose-mode behavior.
        .ignoresSafeArea()
    }

    // MARK: - Submit (draft → real session promotion)

    /// Mirror of `RootView2.submit` — kept on the VC so the
    /// compose-stack SwiftUI host can call back via the closure
    /// installed on `TranscriptDetailComposeStack`.
    private func submit(_ submission: InputBarView2.Submission, sessionId: String) {
        let session = sessionManager.prepareDraftSession(sessionId)
        let isFirstStart = !session.hasRecord
        if isFirstStart {
            // The configurator's bindings have already written cwd /
            // originPath / useWorktree / sourceBranch onto `session.draft`,
            // so promotion picks them up verbatim. Only the
            // `recentProjects` bookkeeping and the home-fallback for users
            // who somehow submit with no folder picked live here now.
            if session.cwd == nil, let draft = session.draft {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                draft.setCwd(home)
                draft.setOriginPath(home)
            }
            if let picked = session.cwd {
                recentProjects.markLaunched(picked, useWorktree: session.isWorktree)
            }
        }
        let mentions = submission.filePaths.map { "@\"\($0)\"" }.joined(separator: " ")
        let composedBody: String = {
            switch (mentions.isEmpty, submission.text.isEmpty) {
            case (true, _): return submission.text
            case (false, true): return mentions
            case (false, false): return mentions + " " + submission.text
            }
        }()
        if submission.images.isEmpty {
            session.send(text: composedBody)
        } else {
            session.send(
                images: submission.images,
                caption: composedBody.isEmpty ? nil : composedBody
            )
        }
        if isFirstStart {
            sessionManager.refreshRecords()
            model.selection = .session(sessionId)
            model.draftSessionId = nil
        }
    }

    deinit {
        runningObservationTask?.cancel()
        selectionObservationTask?.cancel()
        launchFailureObservationTask?.cancel()
        pendingActivationObservationTask?.cancel()
    }
}

// MARK: - SwiftUI overlay subviews

/// Compose-mode card OR chat-mode resting input bar. Same shape as
/// `RootView2.composeStack`, but reads state from the shared
/// `MainSelectionModel` (so the AppKit VC can drive selection /
/// draft flips imperatively from outside SwiftUI).
struct TranscriptDetailComposeStack: View {
    @Bindable var model: MainSelectionModel
    let onSubmit: (InputBarView2.Submission, String) -> Void
    let onResumeSession: (String) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void

    @Environment(SessionManager.self) private var manager

    /// Routing decision for this overlay. Static + pure so the
    /// "which selection shows what input chrome" invariant is
    /// directly unit-testable — see `TranscriptDetailRoutingTests`.
    /// In particular, `.archive` / `.demo` / `.none` all collapse to
    /// `.none` here, which is what keeps the input bar from rendering
    /// on top of (and intercepting clicks on) the Archive page.
    enum Content: Equatable {
        case none
        case compose(draftSessionId: String)
        case chat(sessionId: String)
    }

    static func content(for selection: MainSelection, draftSessionId: String?) -> Content {
        switch selection {
        case .none, .archive:
            return .none
        #if DEBUG
        case .demo:
            return .none
        #endif
        case .newSession:
            // No draft allocated yet (briefly true on first entry
            // before `handleSelectionChanged` lazy-allocates one) →
            // render nothing rather than fabricating a session id.
            guard let did = draftSessionId else { return .none }
            return .compose(draftSessionId: did)
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
            case .compose(let sid):
                composeBody(sid: sid)
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
                .id(sid)
            }
        }
        // Width-infinite always (the host is leading/trailing-pinned).
        // Height is intentionally NOT `.infinity`: in chat mode the
        // host is bottom-anchored to its intrinsic height (driven by
        // ChatRestingBar's content), so a finite fitting size is what
        // lets the host shrink and uncovers the scrim band above the
        // bar for transcript clicks. Compose mode forces full height
        // via an AppKit constraint, not via SwiftUI.
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.42), value: model.isComposeMode)
        .coordinateSpace(name: TranscriptDetailViewController.detailCoordSpace)
    }

    @ViewBuilder
    private func composeBody(sid: String) -> some View {
        let session = manager.prepareDraftSession(sid)
        let bindings = composeBindings(for: session)
        ZStack {
            DotGridBackground()
            NewSessionConfigurator(
                folderPath: bindings.folder,
                useWorktree: bindings.useWorktree,
                sourceBranch: bindings.sourceBranch,
                onResumeSession: onResumeSession,
                inputBar: {
                    InputBarChrome(
                        sessionId: sid,
                        draftKey: InputDraftStore.newSessionKey,
                        coordSpace: TranscriptDetailViewController.detailCoordSpace,
                        submitEnabled: session.cwd != nil,
                        onSubmit: { submission in onSubmit(submission, sid) },
                        onAttachRect: { _ in },
                        onPillRect: { _ in }
                    )
                }
            )
            .padding(.horizontal, TranscriptDetailViewController.detailHorizontalInset)
            .padding(.vertical, TranscriptDetailViewController.detailVerticalInset)
        }
        .transition(.opacity)
    }

    private struct ComposeBindings {
        let folder: Binding<String?>
        let useWorktree: Binding<Bool>
        let sourceBranch: Binding<String?>
    }

    /// Bind the configurator's three controls straight to
    /// `session.draft.config`. There is no parallel storage on the
    /// selection model — the draft itself is the single source of
    /// truth, so the input bar's completion context and the submit
    /// path both observe the same values without a sync hop.
    private func composeBindings(for session: Session) -> ComposeBindings {
        ComposeBindings(
            folder: Binding(
                get: { session.cwd },
                set: { new in
                    guard let new, let draft = session.draft else { return }
                    draft.setCwd(new)
                    draft.setOriginPath(new)
                }
            ),
            useWorktree: Binding(
                get: { session.isWorktree },
                set: { session.draft?.setWorktree($0) }
            ),
            sourceBranch: Binding(
                get: { session.sourceBranch },
                set: { session.draft?.setSourceBranch($0) }
            )
        )
    }
}

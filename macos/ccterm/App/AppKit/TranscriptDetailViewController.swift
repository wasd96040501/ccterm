import AppKit
import Combine
import Observation
import SwiftUI

/// The main window's detail-pane controller. Owns the transcript
/// `Transcript2ScrollView` directly — created in `loadView()` so the
/// table's mount + `frameDidChange` cascade lives in AppKit's source
/// phase, not in SwiftUI's commit pass (the whole point of #195).
///
/// Around the transcript we mount three full-bleed overlays. All three
/// stay mounted for the lifetime of the VC; their *contents* react to
/// `model.selection`:
/// - top scrim — `TranscriptScrimView` (AppKit, hitTest passthrough)
/// - bottom scrim — `TranscriptBottomScrimView` (AppKit, hitTest
///   passthrough, even-odd cutouts at the attach button + pill)
/// - input bar / compose configurator — `PassthroughHostingView`
///   (NSHostingView subclass that lets transparent SwiftUI regions
///   click-through). Its SwiftUI body switches on `model.selection`
///   via `TranscriptDetailComposeStack.content(...)`: `.newSession` →
///   compose card, `.session(_)` → chat resting bar, and `.archive` /
///   `.demo` / `.none` → `EmptyView`. The EmptyView + passthrough
///   combination is what keeps clicks reaching the side-branch view
///   (Archive page, demo VCs) sitting below the overlay.
///
/// Side branches (archive page, DEBUG transcript demos) are hosted via
/// child `NSHostingController`s that take over the detail area when
/// the sidebar selection lands on their sentinel tag.
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
    /// compose card stays SwiftUI-hosted via `PassthroughHostingView`
    /// so transparent regions (when the selection routes to a side
    /// branch and the body collapses to `EmptyView`) click through to
    /// the side-branch view sitting below.
    private var topScrim: TranscriptScrimView!
    private var bottomScrim: TranscriptBottomScrimView!
    private var composeOrBarHost: PassthroughHostingView!

    /// Sink for `model.attachRect` / `pillRect` → `bottomScrim` cutout
    /// path. Re-arms on every fire.
    private var scrimRectObservationTask: Task<Void, Never>?

    /// Side-branch (archive / demo) child VC, mounted via
    /// `addChild` + `view.addSubview`. nil while a session is shown.
    private var sideBranchController: NSViewController?

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

        composeOrBarHost = PassthroughHostingView(rootView: AnyView(makeComposeOrBarStack()))
        composeOrBarHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composeOrBarHost)

        // Each scrim is sized to its visible band, anchored to its edge.
        // Cutout coordinates arrive in `composeOrBarHost`'s SwiftUI
        // coord space; `applyScrimCutouts` translates them into the
        // bottom scrim's local coord via `convert(_:from:)`.
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
            composeOrBarHost.topAnchor.constraint(equalTo: view.topAnchor),
            composeOrBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
        startScrimRectObservation()
    }

    private func startScrimRectObservation() {
        scrimRectObservationTask?.cancel()
        scrimRectObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.model.attachRect
                    _ = self.model.pillRect
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.applyScrimCutouts()
            self.startScrimRectObservation()
        }
    }

    private func applyScrimCutouts() {
        bottomScrim.attachRect = bottomScrim.convert(model.attachRect, from: composeOrBarHost)
        bottomScrim.pillRect = bottomScrim.convert(model.pillRect, from: composeOrBarHost)
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

        rebuildBackingContent()
    }

    // MARK: - Backing content rebuild

    private func rebuildBackingContent() {
        // Detail-pane router. Switch on the typed selection so the
        // compiler enforces that every case has a deliberate route —
        // transcript (chat chrome stays mounted around it, with the
        // compose host's SwiftUI body driven by the selection) or a
        // side-branch view (archive / demo), or nothing (no selection).
        if let kind = Self.sideBranchKind(for: model.selection) {
            tearDownTranscript()
            mountSideBranch(makeSideBranch(kind: kind))
            return
        }
        tearDownSideBranch()

        guard let active = model.effectiveSessionId else {
            tearDownTranscript()
            return
        }
        attachSession(active)
    }

    /// Pure routing decision: which side-branch view (if any) the
    /// `selection` should mount under the detail pane's overlays.
    /// Returning `nil` means the detail pane should mount the
    /// transcript instead. Static + pure so it's directly unit-testable
    /// — see `TranscriptDetailRoutingTests`.
    static func sideBranchKind(for selection: MainSelection) -> SideBranchKind? {
        switch selection {
        case .none, .newSession, .session:
            return nil
        case .archive:
            return .archive
        #if DEBUG
        case .demo(let kind):
            return .demo(kind)
        #endif
        }
    }

    enum SideBranchKind: Equatable {
        case archive
        #if DEBUG
        case demo(DemoKind)
        #endif
    }

    private enum SideBranchContent {
        case swiftUI(AnyView)
        case viewController(NSViewController)
    }

    private func makeSideBranch(kind: SideBranchKind) -> SideBranchContent {
        switch kind {
        case .archive:
            let folderBinding = Binding<String?>(
                get: { [weak self] in self?.model.archiveSelectedFolderPath },
                set: { [weak self] in self?.model.archiveSelectedFolderPath = $0 }
            )
            return .swiftUI(
                AnyView(
                    ArchiveView(
                        selectedFolderPath: folderBinding,
                        onUnarchive: { [weak self] resumeSid in
                            self?.model.selection = .session(resumeSid)
                        }
                    )
                    .environment(sessionManager)
                    .environment(recentProjects)
                    .environment(inputDraftStore)
                    .environment(\.syntaxEngine, searchEngine)
                    .environment(searchBus)
                    .environment(notifications)
                ))
        #if DEBUG
        case .demo(let demoKind):
            switch demoKind {
            case .transcript:
                return .viewController(
                    TranscriptDemoViewController(syntaxEngine: searchEngine))
            case .transcriptStress:
                return .viewController(
                    TranscriptStressViewController(syntaxEngine: searchEngine))
            case .transcriptPerf:
                return .viewController(
                    TranscriptPerfDemoViewController(syntaxEngine: searchEngine))
            case .permissionCards:
                return .swiftUI(AnyView(injectingEnvironment(PermissionCardsDemoView())))
            case .permissionSession:
                return .viewController(
                    PermissionSessionDemoViewController(syntaxEngine: searchEngine))
            }
        #endif
        }
    }

    private func mountSideBranch(_ content: SideBranchContent) {
        tearDownSideBranch()
        let host: NSViewController
        switch content {
        case .swiftUI(let anyView):
            host = NSHostingController(rootView: anyView)
        case .viewController(let vc):
            host = vc
        }
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        // Insert below the chat-chrome overlays. The compose host's
        // SwiftUI body is `EmptyView` for side-branch selections (see
        // `TranscriptDetailComposeStack.content(...)`), and
        // `PassthroughHostingView` lets the resulting transparent
        // region click-through, so the side branch receives clicks
        // even though it sits below the host in the subview stack.
        view.addSubview(host.view, positioned: .below, relativeTo: topScrim)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        sideBranchController = host
    }

    private func tearDownSideBranch() {
        guard let controller = sideBranchController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        sideBranchController = nil
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
            }
        )
        .environment(sessionManager)
        .environment(recentProjects)
        .environment(inputDraftStore)
        .environment(\.syntaxEngine, searchEngine)
        .environment(searchBus)
        .environment(notifications)
        // Without `.ignoresSafeArea()`, `NSHostingView` would forward a
        // toolbar-sized top safe-area inset to SwiftUI; the rects
        // reported in `detailCoordSpace` would then sit in an inset
        // coord space while `bottomScrim` (full-bleed AppKit) renders
        // in `view.bounds`, so the cutouts would land
        // `toolbarHeight` pixels too high. KNOWN ISSUE: this also
        // makes the SwiftUI body extend behind the scrim's visible
        // band, and mouse events in that band are intercepted instead
        // of passing through to the transcript. Tracking separately.
        .ignoresSafeArea()
    }

    private func injectingEnvironment<V: View>(_ inner: V) -> some View {
        inner
            .environment(sessionManager)
            .environment(recentProjects)
            .environment(inputDraftStore)
            .environment(\.syntaxEngine, searchEngine)
            .environment(searchBus)
            .environment(notifications)
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
        scrimRectObservationTask?.cancel()
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
                    onAttachRect: { model.attachRect = $0 },
                    onPillRect: { model.pillRect = $0 }
                )
                .id(sid)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

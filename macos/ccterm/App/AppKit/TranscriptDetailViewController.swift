import AppKit
import Combine
import Observation
import SwiftUI

/// The main window's detail-pane controller. Owns the transcript
/// `Transcript2ScrollView` directly — created in `loadView()` so the
/// table's mount + `frameDidChange` cascade lives in AppKit's source
/// phase, not in SwiftUI's commit pass (the whole point of #195).
///
/// Around the transcript, SwiftUI is hosted via three lightweight
/// `NSHostingView`s:
/// - top scrim
/// - bottom scrim (with model-driven cut-outs for the attach button +
///   pill)
/// - input bar / compose configurator (one host, contents switch on
///   `model.selection` via `TranscriptDetailComposeStack.content(...)`
///   — `.archive` / `.demo` collapse to `EmptyView`, so side-branch
///   pages have no input chrome floating on top of them)
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
    private static let topFadeScrimHeight: CGFloat = 80
    private static let bottomFadeScrimHeight: CGFloat = 160
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
    /// Hosted SwiftUI overlays that make up the chat-pane chrome
    /// (top fade scrim, bottom fade scrim with attach/pill cut-outs,
    /// input-bar / compose configurator). All three mount together via
    /// `mountChatChromeIfNeeded()` when the selection routes to a
    /// transcript, and unmount together via `tearDownChatChrome()` when
    /// the selection routes to a side branch (Archive / demo) — so
    /// side-branch pages aren't sitting under any chat-only overlay
    /// that could intercept clicks or draw a scrim cut-out into them.
    private var topScrimHost: NSHostingView<AnyView>?
    private var bottomScrimHost: NSHostingView<AnyView>?
    private var composeOrBarHost: NSHostingView<AnyView>?

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
        // — we just need a plain container view here. Chat chrome
        // (scrims + input bar) and the transcript itself mount lazily
        // via `rebuildBackingContent()` so side-branch selections
        // (Archive / demo) don't carry any chat-only overlay.
        view = NSView()
    }

    /// Lazily mount the three SwiftUI chat-pane overlays. Idempotent
    /// (no-op if they're already attached). Must run before
    /// `attachSession(_:)` because the transcript scroll view is
    /// positioned `.below` `topScrimHost`.
    private func mountChatChromeIfNeeded() {
        guard topScrimHost == nil else { return }

        let top = NSHostingView(rootView: AnyView(makeTopScrim()))
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        topScrimHost = top

        let bottom = NSHostingView(rootView: AnyView(makeBottomScrim()))
        bottom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottom)
        bottomScrimHost = bottom

        let bar = NSHostingView(rootView: AnyView(makeComposeOrBarStack()))
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        composeOrBarHost = bar

        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.topAnchor.constraint(equalTo: view.topAnchor),
            top.heightAnchor.constraint(equalToConstant: Self.topFadeScrimHeight),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: Self.bottomFadeScrimHeight),

            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func tearDownChatChrome() {
        topScrimHost?.removeFromSuperview()
        topScrimHost = nil
        bottomScrimHost?.removeFromSuperview()
        bottomScrimHost = nil
        composeOrBarHost?.removeFromSuperview()
        composeOrBarHost = nil
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
        // transcript + chat chrome, side-branch view (archive / demo)
        // with no chat chrome at all, or nothing (no selection).
        if let kind = Self.sideBranchKind(for: model.selection) {
            tearDownTranscript()
            tearDownChatChrome()
            mountSideBranch(makeSideBranch(kind: kind))
            return
        }
        tearDownSideBranch()

        guard let active = model.effectiveSessionId else {
            tearDownTranscript()
            tearDownChatChrome()
            return
        }
        mountChatChromeIfNeeded()
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
        // Chat chrome has been torn down by the time we reach here
        // (see `rebuildBackingContent`), so the side branch can simply
        // attach at the top of the subview stack — no z-ordering needed.
        view.addSubview(host.view)
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
        // `mountChatChromeIfNeeded()` was just called by
        // `rebuildBackingContent`, so `topScrimHost` is non-nil here —
        // place the transcript under it so the top fade sits over the
        // first row of content.
        view.addSubview(scroll, positioned: .below, relativeTo: topScrimHost)
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

    private func makeTopScrim() -> some View {
        // `.ignoresSafeArea()` is essential: with `fullSizeContentView`,
        // the detail view extends behind the toolbar, but NSHostingView
        // forwards the parent's safe-area insets to its SwiftUI content
        // by default — without this, the gradient draws *below* the
        // toolbar instead of behind it.
        FadeScrim(.topToBottom, height: Self.topFadeScrimHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }

    private func makeBottomScrim() -> some View {
        TranscriptDetailBottomScrim(model: model, height: Self.bottomFadeScrimHeight)
            .ignoresSafeArea()
    }

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
    }
}

// MARK: - SwiftUI overlay subviews

/// Bottom fade scrim, mirroring `RootView2.detailContentReleaseBranches`'s
/// `.overlay(alignment: .bottom)`. Reads attach + pill rects from the
/// shared `MainSelectionModel` so the cut-outs follow the input bar's
/// reported geometry.
private struct TranscriptDetailBottomScrim: View {
    @Bindable var model: MainSelectionModel
    let height: CGFloat

    var body: some View {
        FadeScrim(.bottomToTop, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .mask {
                Color.white
                    .overlay {
                        if model.attachRect != .zero {
                            Circle()
                                .fill(.black)
                                .frame(
                                    width: model.attachRect.width,
                                    height: model.attachRect.height
                                )
                                .position(x: model.attachRect.midX, y: model.attachRect.midY)
                                .blendMode(.destinationOut)
                        }
                        if model.pillRect != .zero {
                            RoundedRectangle(
                                cornerRadius: InputBarView2.cornerRadius,
                                style: .continuous
                            )
                            .fill(.black)
                            .frame(
                                width: model.pillRect.width,
                                height: model.pillRect.height
                            )
                            .position(x: model.pillRect.midX, y: model.pillRect.midY)
                            .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

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

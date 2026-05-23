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
///   `model.isComposeMode`)
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
    /// Hosted SwiftUI overlays. All three are added to `view` once and
    /// stay mounted for the lifetime of the VC — the SwiftUI content
    /// they render reads from `model` and reactively switches form.
    private var topScrimHost: NSHostingView<AnyView>!
    private var bottomScrimHost: NSHostingView<AnyView>!
    private var composeOrBarHost: NSHostingView<AnyView>!

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
    /// Sink for `model.draftCwd` → `Session.draft.setCwd`.
    private var draftCwdObservationTask: Task<Void, Never>?

    // MARK: - Attach probe (TEMPORARY — investigating PR #205 top-then-snap)
    private var attachProbeStart: CFAbsoluteTime?
    private var attachProbeDeadline: CFAbsoluteTime?
    private var attachProbeRunLoopObserver: CFRunLoopObserver?
    private var attachProbeBoundaryCounter: Int = 0
    private var attachProbeLastModel: CGFloat?
    private var attachProbeLastPresentation: CGFloat?
    private var attachProbeLastTableH: CGFloat?
    private var attachProbeLastScrollerKnob: Double?
    private var attachProbeLastScrollerAlphaQuanta: Int?

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

        topScrimHost = NSHostingView(rootView: AnyView(makeTopScrim()))
        topScrimHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topScrimHost)

        bottomScrimHost = NSHostingView(rootView: AnyView(makeBottomScrim()))
        bottomScrimHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomScrimHost)

        composeOrBarHost = NSHostingView(rootView: AnyView(makeComposeOrBarStack()))
        composeOrBarHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composeOrBarHost)

        NSLayoutConstraint.activate([
            topScrimHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topScrimHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topScrimHost.topAnchor.constraint(equalTo: view.topAnchor),
            topScrimHost.heightAnchor.constraint(equalToConstant: Self.topFadeScrimHeight),

            bottomScrimHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomScrimHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomScrimHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomScrimHost.heightAnchor.constraint(equalToConstant: Self.bottomFadeScrimHeight),

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
        // `RootView2`'s `.task(id: selectedSessionId)` which fired once
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
        startDraftCwdObservation()
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
                    _ = self.model.selectedSessionId
                    _ = self.model.draftSessionId
                    _ = self.model.isComposeMode
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
                self.model.selectedSessionId = sid
                self.notifications.clearPendingActivation()
            }
            self.startPendingActivationObservation()
        }
    }

    private func startDraftCwdObservation() {
        draftCwdObservationTask?.cancel()
        draftCwdObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.model.draftCwd
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.applyDraftCwdIfNeeded()
            self.startDraftCwdObservation()
        }
    }

    private func applyDraftCwdIfNeeded() {
        guard model.isComposeMode,
            let sid = model.draftSessionId,
            let cwd = model.draftCwd
        else { return }
        sessionManager.prepareDraftSession(sid).draft?.setCwd(cwd)
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
        // Lazy-allocate draftSessionId on entering New Session.
        if model.selectedSessionId == SidebarView2.newSessionTag, model.draftSessionId == nil {
            model.draftSessionId = UUID().uuidString.lowercased()
            model.draftCwd = recentProjects.lastLaunchedPath
            model.draftUseWorktree =
                model.draftCwd.flatMap { recentProjects.useWorktree(for: $0) } ?? false
            model.draftSourceBranch = nil
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
        let sid = model.selectedSessionId

        // Side branch path (archive / demo views).
        let sideBranch = sideBranchView(for: sid)
        if sideBranch != nil {
            tearDownTranscript()
            mountSideBranch(sideBranch!, key: sid ?? "")
            return
        }
        tearDownSideBranch()

        guard let active = model.effectiveSessionId else {
            tearDownTranscript()
            return
        }
        attachSession(active)
    }

    private func sideBranchView(for sid: String?) -> AnyView? {
        guard let sid else { return nil }
        if sid == SidebarView2.archiveTag {
            return AnyView(
                ArchiveView(onUnarchive: { [weak self] resumeSid in
                    self?.model.selectedSessionId = resumeSid
                })
                .environment(sessionManager)
                .environment(recentProjects)
                .environment(inputDraftStore)
                .environment(\.syntaxEngine, searchEngine)
                .environment(searchBus)
                .environment(notifications)
            )
        }
        #if DEBUG
        switch sid {
        case SidebarView2.transcriptDemoTag:
            return AnyView(injectingEnvironment(TranscriptDemoView()))
        case SidebarView2.transcriptStressTag:
            return AnyView(injectingEnvironment(TranscriptStressView()))
        case SidebarView2.transcriptPerfTag:
            return AnyView(injectingEnvironment(TranscriptPerfDemoView()))
        case SidebarView2.permissionCardsDemoTag:
            return AnyView(injectingEnvironment(PermissionCardsDemoView()))
        case SidebarView2.permissionSessionDemoTag:
            return AnyView(injectingEnvironment(PermissionSessionDemoView()))
        default: break
        }
        #endif
        return nil
    }

    private func mountSideBranch(_ content: AnyView, key: String) {
        tearDownSideBranch()
        let host = NSHostingController(rootView: content)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        // Insert at index 0 so the side-branch view sits under the
        // overlays (scrim / input bar / compose card). Side branches
        // bring their own chrome but still benefit from the top
        // scrim's softening.
        view.addSubview(host.view, positioned: .below, relativeTo: topScrimHost)
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
        let isReEntry = currentSession != nil
        startAttachProbe()
        appLog(
            .info, "TranscriptAttachProbe",
            "P0 attach.enter sid=\(sessionId.prefix(8)) reEntry=\(isReEntry) "
                + "priorBlocks=\(currentSession?.controller.blockCount ?? -1) "
                + "newBlocks=\(session.controller.blockCount)")
        appLog(.info, "TranscriptAttachProbe", "T0 tearDown.enter")
        tearDownTranscript()
        appLog(.info, "TranscriptAttachProbe", "T1 tearDown.exit")

        let scroll = TranscriptScrollViewFactory.make(controller: session.controller)
        let probeTable = scroll.documentView as? NSTableView
        appLog(
            .info, "TranscriptAttachProbe",
            "P1 factory.make insets={t=\(scroll.contentInsets.top),b=\(scroll.contentInsets.bottom)} "
                + "tableFrame=\(probeTable?.frame ?? .zero) "
                + "tableRows=\(probeTable?.numberOfRows ?? -1)")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll, positioned: .below, relativeTo: topScrimHost)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        appLog(
            .info, "TranscriptAttachProbe",
            "P2 addSubview scrollFrame=\(scroll.frame) "
                + "clipFrame=\(scroll.contentView.frame) "
                + "tableFrame=\(probeTable?.frame ?? .zero)")
        // Pull layout into the current call stack so the table reaches
        // its real width before any downstream work (history load, scroll
        // anchor, setLoading) runs. Without this, attachSession would
        // return with width=0 and every "first tile" piece downstream
        // would have to defer through `tableFrameDidChange` + async hops.
        view.layoutSubtreeIfNeeded()
        appLog(
            .info, "TranscriptAttachProbe",
            "P3 postLayout scrollFrame=\(scroll.frame) "
                + "clipFrame=\(scroll.contentView.frame) "
                + "clipBounds.origin.y=\(scroll.contentView.bounds.origin.y) "
                + "tableFrame=\(probeTable?.frame ?? .zero) "
                + "tableRows=\(probeTable?.numberOfRows ?? -1) "
                + scrollerDump(scroll, tag: "P3"))
        transcriptScroll = scroll
        currentSession = session

        // Re-attach scroll: bridge-accumulated blocks from a previous
        // mount land here with no setHistory follow-up (loadHistory is
        // idempotent and short-circuits). Anchor to the tail synchronously
        // now that the table has real width.
        session.controller.scrollToTail()
        appLog(
            .info, "TranscriptAttachProbe",
            "P4 postScrollToTail clipBounds.origin.y=\(scroll.contentView.bounds.origin.y) "
                + "presentation.origin.y="
                + "\(scroll.contentView.layer?.presentation()?.bounds.origin.y.description ?? "nil") "
                + "tableFrame=\(probeTable?.frame ?? .zero) "
                + scrollerDump(scroll, tag: "P4"))

        // Attach syntax engine (idempotent).
        session.controller.attachSyntaxEngine(searchEngine)

        // Kick history load + initial running pill sync (mirrors
        // `ChatHistoryView.task(id: sessionId)`).
        appLog(
            .info, "TranscriptDetailVC",
            "[history] attach session=\(sessionId.prefix(8))… "
                + "loadState=\(String(describing: session.historyLoadState)) "
                + "msgCount=\(session.messages.count) "
                + "blockCount=\(session.controller.blockCount)")
        appLog(
            .info, "TranscriptAttachProbe",
            "P5a preLoadHistory clip.origin.y=\(scroll.contentView.bounds.origin.y)")
        session.loadHistory()
        appLog(
            .info, "TranscriptAttachProbe",
            "P5b postLoadHistory clip.origin.y=\(scroll.contentView.bounds.origin.y)")
        session.controller.setLoading(session.isRunning)
        appLog(
            .info, "TranscriptAttachProbe",
            "P5c postSetLoading clip.origin.y=\(scroll.contentView.bounds.origin.y) "
                + "tableH=\(probeTable?.frame.height ?? 0)")

        // Re-arm the `isRunning` → `setLoading` sink.
        startRunningObservation(for: session)
        appLog(
            .info, "TranscriptAttachProbe",
            "P6 attach.exit clip.origin.y=\(scroll.contentView.bounds.origin.y) "
                + "presentation.origin.y="
                + "\(scroll.contentView.layer?.presentation()?.bounds.origin.y.description ?? "nil") "
                + "tableH=\(probeTable?.frame.height ?? 0) "
                + scrollerDump(scroll, tag: "P6"))
    }

    /// Dumps the vertical NSScroller's current state — knob position,
    /// knob proportion, alpha, hidden flag, presentation alpha (for
    /// fade-in/out animation tracking). The user-reported "thumb at
    /// top while content at bottom" glitch should surface here as
    /// `doubleValue ≈ 0` while `clip.origin` is at tail.
    private func scrollerDump(_ scroll: NSScrollView, tag: String) -> String {
        guard let s = scroll.verticalScroller else { return "[\(tag) scroller=nil]" }
        let pres = s.layer?.presentation()?.opacity
        return
            "[\(tag) scroller dv=\(String(format: "%.3f", s.doubleValue)) "
            + "knobProp=\(String(format: "%.3f", s.knobProportion)) "
            + "alpha=\(String(format: "%.2f", s.alphaValue)) "
            + "hidden=\(s.isHidden) "
            + "presAlpha=\(pres.map { String(format: "%.2f", $0) } ?? "nil")]"
    }

    private func tearDownTranscript() {
        if let scroll = transcriptScroll, let session = currentSession {
            TranscriptScrollViewFactory.dismantle(scroll, controller: session.controller)
            scroll.removeFromSuperview()
        }
        transcriptScroll = nil
        currentSession = nil
        runningObservationTask?.cancel()
        runningObservationTask = nil
    }

    // MARK: - Attach probe (TEMPORARY)

    /// Installs a CFRunLoopObserver that logs at every `.beforeWaiting`
    /// (after CoreAnimation's commit — order 3,000,000 places us after
    /// CA's own 2,000,000 commit observer) and `.afterWaiting` (new
    /// tick wake) boundary, so we can confirm whether the 143ms attach
    /// crosses multiple runloop iterations and therefore commits
    /// `clip.bounds.origin.y = 0` to the render server before our
    /// `scrollToTail` writes the real value.
    ///
    /// Logging is gated on `attachProbeDeadline` so the stream isn't
    /// noisy outside an active attach window.
    private func startAttachProbe() {
        ensureAttachProbeObserver()
        attachProbeStart = CFAbsoluteTimeGetCurrent()
        attachProbeDeadline = (attachProbeStart ?? 0) + 1.0
        attachProbeBoundaryCounter = 0
        attachProbeLastModel = nil
        attachProbeLastPresentation = nil
        attachProbeLastTableH = nil
        attachProbeLastScrollerKnob = nil
        attachProbeLastScrollerAlphaQuanta = nil
    }

    private func ensureAttachProbeObserver() {
        if attachProbeRunLoopObserver != nil { return }
        let mask = CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, mask, true, 3_000_000
        ) { [weak self] _, activity in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleAttachProbeRunLoopFire(activity: activity)
            }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            attachProbeRunLoopObserver = observer
        }
    }

    private func handleAttachProbeRunLoopFire(activity: CFRunLoopActivity) {
        guard let deadline = attachProbeDeadline,
            let start = attachProbeStart,
            CFAbsoluteTimeGetCurrent() < deadline
        else { return }
        let scroll = transcriptScroll
        let model = scroll?.contentView.bounds.origin.y
        let pres = scroll?.contentView.layer?.presentation()?.bounds.origin.y
        let tableH = (scroll?.documentView as? NSTableView)?.frame.height
        let scroller = scroll?.verticalScroller
        let knob = scroller?.doubleValue
        // Quantize alpha to 10 buckets to avoid noise on every fade
        // animation frame; still catches 0→visible, visible→hidden
        // transitions.
        let alphaQ = scroller.map { Int($0.alphaValue * 10) }
        let presAlpha = scroller?.layer?.presentation()?.opacity

        // Filter: only log when any tracked value changed (incl scroller
        // knob doubleValue and quantized alpha). Breaks the appLog feedback
        // loop while preserving the signal we care about — *especially*
        // scroller-knob and scroller-alpha transitions, since the user
        // reports the glitch IS in the scroller, not the content.
        if model == attachProbeLastModel,
            pres == attachProbeLastPresentation,
            tableH == attachProbeLastTableH,
            knob == attachProbeLastScrollerKnob,
            alphaQ == attachProbeLastScrollerAlphaQuanta
        {
            return
        }
        attachProbeLastModel = model
        attachProbeLastPresentation = pres
        attachProbeLastTableH = tableH
        attachProbeLastScrollerKnob = knob
        attachProbeLastScrollerAlphaQuanta = alphaQ

        attachProbeBoundaryCounter += 1
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let tag: String
        if activity.contains(.beforeWaiting) {
            tag = "BW"
        } else if activity.contains(.afterWaiting) {
            tag = "AW"
        } else {
            tag = "??"
        }
        let m = model.map { String(format: "%.2f", $0) } ?? "nil"
        let p = pres.map { String(format: "%.2f", $0) } ?? "nil"
        let h = tableH.map { String(format: "%.2f", $0) } ?? "nil"
        let kStr = knob.map { String(format: "%.3f", $0) } ?? "nil"
        let aStr = scroller.map { String(format: "%.2f", $0.alphaValue) } ?? "nil"
        let paStr = presAlpha.map { String(format: "%.2f", $0) } ?? "nil"
        let hiddenStr = scroller?.isHidden.description ?? "nil"
        appLog(
            .info, "TranscriptAttachProbe",
            "[\(tag)#\(attachProbeBoundaryCounter)] t+\(String(format: "%.1f", elapsed))ms "
                + "model=\(m) pres=\(p) tableH=\(h) | "
                + "knob=\(kStr) alpha=\(aStr) presAlpha=\(paStr) hidden=\(hiddenStr)")
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
                self.model.selectedSessionId = resumeSid
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
            let chosen = model.draftCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            if let draft = session.draft {
                draft.setOriginPath(chosen)
                draft.setCwd(chosen)
                draft.setWorktree(model.draftUseWorktree)
                if model.draftUseWorktree {
                    draft.setSourceBranch(model.draftSourceBranch)
                }
            }
            if let picked = model.draftCwd {
                recentProjects.markLaunched(picked, useWorktree: model.draftUseWorktree)
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
            model.selectedSessionId = sessionId
            model.draftSessionId = nil
        }
    }

    deinit {
        runningObservationTask?.cancel()
        selectionObservationTask?.cancel()
        launchFailureObservationTask?.cancel()
        pendingActivationObservationTask?.cancel()
        draftCwdObservationTask?.cancel()
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

    var body: some View {
        let sid = model.effectiveSessionId
        ZStack {
            if let sid {
                if model.isComposeMode {
                    composeBody(sid: sid)
                } else {
                    ChatRestingBar(
                        sessionId: sid,
                        draftKey: sid,
                        onSubmit: { submission in onSubmit(submission, sid) },
                        onAttachRect: { model.attachRect = $0 },
                        onPillRect: { model.pillRect = $0 }
                    )
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.42), value: model.isComposeMode)
        .coordinateSpace(name: TranscriptDetailViewController.detailCoordSpace)
    }

    @ViewBuilder
    private func composeBody(sid: String) -> some View {
        let bindings = composeBindings()
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
                        submitEnabled: model.draftCwd != nil,
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

    private func composeBindings() -> ComposeBindings {
        ComposeBindings(
            folder: Binding(
                get: { model.draftCwd },
                set: { model.draftCwd = $0 }
            ),
            useWorktree: Binding(
                get: { model.draftUseWorktree },
                set: { model.draftUseWorktree = $0 }
            ),
            sourceBranch: Binding(
                get: { model.draftSourceBranch },
                set: { model.draftSourceBranch = $0 }
            )
        )
    }
}

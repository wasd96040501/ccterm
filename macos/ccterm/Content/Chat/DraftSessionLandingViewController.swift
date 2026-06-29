import AppKit

/// Full-pane child VC for a `.session(_)` selection whose `Session` is
/// still in `.draft` phase — the landing page for a `/new` / `/clear`
/// draft before its first message. `DetailRouterViewController` mounts this
/// (via the `.draftLanding` child kind) instead of `ChatSessionViewController`
/// while the session is a draft; on first send the session promotes to
/// `.active` and the router swaps in the transcript VC.
///
/// **Why its own VC (vs reusing Compose).** `ComposeSessionViewController`
/// serves the `.newSession` tab and lazily allocates `model.draftSessionId`;
/// this VC instead binds a draft id the router hands it via `present(sessionId:)`,
/// so the same VC instance can re-bind across draft → draft switches.
///
/// **Pure AppKit (migration plan §4.6).** This VC no longer hosts the SwiftUI
/// `DraftSessionLandingView → InputBarChrome`. It builds an AppKit
/// `InputBarController` ONCE in `loadView` (the bar is never rebuilt — a
/// draft → draft switch calls `rebind(sessionId:)` in place) and a
/// `DraftLandingContentView` (`DotGridView` backdrop + centered hero + embedded
/// bar) pinned 4-edge. Regime-A no-collapse is by constraint topology
/// (`DraftLandingContentView.intrinsicContentSize = .zero`), not by
/// `NSHostingController.sizingOptions`.
@MainActor
final class DraftSessionLandingViewController: NSViewController, DetailRouterChild {
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

    /// The detail-scope dependency bag, handed down from the router.
    /// `model` and the four injected services are read through this.
    let context: DetailContext

    /// The draft session this VC is currently bound to. Driven by the router's
    /// `present(sessionId:)`; a draft → draft switch re-keys the bar + re-renders
    /// the hero in place (never rebuilds either).
    private var boundSessionId: String?

    /// The embedded input bar, built ONCE in `loadView` (plan §4.0/§4.6). Draft
    /// landing passes `autofocus: true` so the field focuses once the bar is
    /// windowed; `rebind(sessionId:)` re-fires focus on every bind. `private(set)`
    /// so the CI-gate tests can drive `handleSend` + assert identity-stability
    /// across rebind without a write seam.
    private(set) var inputBarController: InputBarController!

    /// The fill-the-pane content root (`DotGridView` + hero + embedded bar). The
    /// hero re-renders per bind via `update(session:)`; the bar is left untouched.
    private var contentView: DraftLandingContentView!

    init(context: DetailContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()

        // Build the embedded bar ONCE (plan §4.0). It is a child VC so its
        // child-VC lifecycle (`viewDidAppear` autofocus gating) fires; draft
        // landing sets `autofocus: true`. `onBuiltinCommand` runs the builtin
        // (`/new`, `/clear`) against the controller's bound session id, mirroring
        // `ChatSessionViewController`'s relay.
        let bar = InputBarController(
            sessionManager: context.sessionManager,
            inputDraftStore: context.inputDraftStore,
            autofocus: true,
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
            submitEnabledProvider: { $0.cwd != nil },
            onSubmit: { [weak self] submission, sessionId in
                guard let self else { return }
                submitSessionInput(
                    submission,
                    sessionId: sessionId,
                    sessionManager: self.context.sessionManager,
                    recentProjects: self.context.recentProjects,
                    model: self.context.model)
            })
        addChild(bar)
        inputBarController = bar
        // Force the bar's `loadView` now so `barView` / `chromeRow` exist before
        // the content view stacks them (their implicitly-unwrapped properties are
        // nil until the view loads).
        bar.loadViewIfNeeded()

        // Fill-the-pane content: hero + embedded bar over the dot grid. Pinned
        // 4-edge; regime-A no-collapse is by constraint topology (the content
        // view publishes `.zero` intrinsic).
        contentView = DraftLandingContentView(barView: bar.barView, chromeRow: bar.chromeRow)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// `DetailRouterChild` — the router calls this right before it swaps this VC
    /// out on a cross-kind transition (draft → transcript on promotion). Tear the
    /// bar down deterministically (cancel draft-load Task, `completion.dismiss`,
    /// image-preview stop, chrome-row popover/timer teardown) so it doesn't leak
    /// during the crossfade window (plan §4.6-7, R5) — was a no-op before the
    /// AppKit re-point.
    func prepareForRemoval() {
        inputBarController?.prepareForRemoval()
    }

    /// Bind (or re-bind) the landing page to `sessionId`. Called by the router
    /// synchronously after this VC is mounted and framed, mirroring
    /// `ChatSessionViewController.present(sessionId:)`. Idempotent for the same
    /// id; a different id re-keys the bar in place (`rebind(sessionId:)`, NEVER
    /// rebuild) and re-renders the hero (`update(session:)`).
    func present(sessionId: String?, animated: Bool = false) {
        guard let sessionId else { return }
        guard sessionId != boundSessionId else { return }
        boundSessionId = sessionId
        updateFocus(activeSessionId: sessionId)
        // Resolve the draft once (idempotent get-or-create) and hand the SAME
        // instance to both the hero re-render and the bar's `rebind`.
        let session = context.sessionManager.prepareDraftSession(sessionId)
        // Per-draft key (`draftKey` defaults to `sessionId`): each draft has its
        // own unsent input, distinct from compose's `newSessionKey`. `rebind`
        // resets text/attachments/completion + re-arms cwd/prewarm observation +
        // re-fires autofocus.
        inputBarController.rebind(sessionId: sessionId)
        contentView.update(session: session)
    }

    /// Mark the bound draft focused and defocus every other session — the same
    /// sweep `ChatSessionViewController.updateFocus` runs on attach. Without it a
    /// session the user just navigated AWAY from via `/new` would keep
    /// `isFocused == true` and suppress its unread dot when its CLI produces
    /// background output. (Preserved verbatim from the SwiftUI-host version.)
    private func updateFocus(activeSessionId: String) {
        context.sessionManager.existingSession(activeSessionId)?.setFocused(true)
        for sid in context.sessionManager.records.map(\.sessionId) where sid != activeSessionId {
            context.sessionManager.existingSession(sid)?.setFocused(false)
        }
    }
}

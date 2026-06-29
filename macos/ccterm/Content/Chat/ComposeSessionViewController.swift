import AppKit

/// Full-pane child VC for the New Session (`.newSession`) selection.
/// `DetailRouterViewController` mounts this — and only this — for
/// `.newSession`; `.session(_)` / `.none` go to `ChatSessionViewController`.
///
/// **Why compose is its own VC.** Compose used to be a *mode* of
/// `ChatSessionViewController`, sharing its always-mounted bar host. That host
/// had to morph between a full-bleed configurator (compose) and a
/// bottom-anchored bar (chat) on every selection flip, which meant keeping an
/// AppKit constraint switch in sync across runloop phases — the full-bleed host
/// lingered over the transcript after a fast switch and swallowed its clicks.
/// Giving compose its own VC deletes the shared surface: this VC is full-bleed
/// with nothing behind it, and the chat VC's bar host is now *always*
/// bottom-anchored.
///
/// **Pure AppKit (migration plan §4.6).** This VC no longer hosts the SwiftUI
/// `ComposeSessionView → NewSessionConfigurator + InputBarChrome`. It builds an
/// AppKit `InputBarController` once, a `NewSessionConfiguratorViewController`
/// that embeds it, and wraps both in a `ComposeContentView` (`DotGridView`
/// backdrop + centered card) pinned 4-edge. Regime-A no-collapse is by
/// constraint topology (`ComposeContentView.intrinsicContentSize = .zero` + the
/// card's non-required min-size band), not by `NSHostingController.sizingOptions`
/// — there is no hosting controller anymore.
@MainActor
final class ComposeSessionViewController: NSViewController, DetailRouterChild {
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

    /// The detail-scope dependency bag, handed down from the router.
    /// `model` and the four injected services are read through this.
    let context: DetailContext

    /// The embedded input bar, built ONCE in `viewDidLoad`. Bound to the compose
    /// draft (keyed on `InputDraftStore.newSessionKey`) by the configurator's
    /// `viewDidLoad`. `private(set)` so the CI-gate tests can drive the real
    /// `handleSend` / read `canSend` without a write seam.
    private(set) var inputBarController: InputBarController!

    /// The AppKit compose card configurator. Owns the embedded bar's POSITION +
    /// the folder/branch/worktree/recents wiring. Held so `prepareForRemoval`
    /// can drive its teardown (the bar is torn down through it).
    private(set) var configurator: NewSessionConfiguratorViewController!

    init(context: DetailContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Resolve the draft session id this card binds to up front and bind it
        // as a plain value — NOT read reactively from `model.draftSessionId`. On
        // submit we flip `selection` to `.session(_)` and nil out
        // `draftSessionId`; a reactive read would blank the configurator for the
        // one tick before the router swaps this VC out (plan §4.6-7, R16).
        let draftSessionId = ensureDraftSession()

        // The embedded bar, built ONCE (plan §4.0/§4.6). Compose leaves
        // `autofocus` false (matching the SwiftUI compose card, which set no
        // autofocus on its `InputBarChrome`) and `onBuiltinCommand` nil (builtins
        // are not offered in compose — `ComposeSessionView` omitted it). The
        // `submitEnabledProvider` reads the bound session's `cwd` so the send
        // button enables only once a folder is picked; the bar observes
        // `session.cwd` and re-fires it on each recents/NSOpenPanel pick.
        let bar = InputBarController(
            sessionManager: context.sessionManager,
            inputDraftStore: context.inputDraftStore,
            autofocus: false,
            onBuiltinCommand: nil,
            submitEnabledProvider: { $0.cwd != nil },
            onSubmit: { [weak self] submission, sessionId in
                guard let self else { return }
                // `sessionId` is the bound `draftSessionId` the controller
                // supplies; forward verbatim to the shared promote handler.
                submitSessionInput(
                    submission,
                    sessionId: sessionId,
                    sessionManager: self.context.sessionManager,
                    recentProjects: self.context.recentProjects,
                    model: self.context.model)
            })
        inputBarController = bar

        // The configurator embeds + rebinds the bar in its own `loadView` /
        // `viewDidLoad` (it `addChild`s the bar, places its pill + chrome row in
        // the card, and calls `rebind(sessionId: draftSessionId, draftKey:
        // newSessionKey)`). A recents-row click writes the SAME draft's cwd, so
        // the bar's cwd/prewarm observation tracks it (plan §4.6-6).
        let configurator = NewSessionConfiguratorViewController(
            sessionManager: context.sessionManager,
            recents: context.recentProjects,
            inputBarController: bar,
            draftSessionId: draftSessionId,
            onResumeSession: { [weak self] resumeSid in
                guard let self else { return }
                self.context.model.select(.session(resumeSid))
                self.context.model.draftSessionId = nil
            })
        self.configurator = configurator
        addChild(configurator)

        // Fill-the-pane content: `DotGridView` backdrop + the centered card.
        // Regime-A no-collapse is by constraint topology (the content view +
        // card publish `.zero` / non-required min-size), pinned 4-edge here.
        let content = ComposeContentView(configurator: configurator)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// `DetailRouterChild` — the router calls this exactly when it removes this
    /// VC on a cross-kind swap (compose → transcript on submit, or compose →
    /// archive/another session), in BOTH the synchronous and crossfade removal
    /// paths (`DetailRouterViewController.installChildForCurrentSelection` /
    /// `finishFadeOut`). Driving teardown here instead of `viewWillDisappear`
    /// (plan §4.6-7, R16) means a transient occlusion (window miniaturize /
    /// restore, which also fires `viewWillDisappear` but keeps the VC mounted
    /// in the router) does NOT tear the bar down and leave it inert with no
    /// re-arm path. `configurator.teardown` cancels the git-probe Task, closes
    /// any open popover, and calls `inputBarController.prepareForRemoval()`
    /// (cancel draft-load Task, `completion.dismiss`, image-preview stop,
    /// chrome-row popover/timer teardown).
    func prepareForRemoval() {
        configurator?.teardown()
    }

    /// Lazy-allocate `model.draftSessionId` on first entry into New Session,
    /// seeding the draft's `cwd` / `originPath` so `session.cwd` is non-nil
    /// before the configurator + bar's completion context first read it.
    /// `useWorktree` / `sourceBranch` are left to the configurator's
    /// `applyProbeBindings` to fill off the git probe. Returns the resolved id.
    private func ensureDraftSession() -> String {
        if let existing = context.model.draftSessionId { return existing }
        let sid = UUID().uuidString.lowercased()
        context.model.draftSessionId = sid
        if let cwd = context.recentProjects.lastLaunchedPath,
            let draft = context.sessionManager.prepareDraftSession(sid).draft
        {
            draft.setCwd(cwd)
            draft.setOriginPath(cwd)
        }
        return sid
    }
}

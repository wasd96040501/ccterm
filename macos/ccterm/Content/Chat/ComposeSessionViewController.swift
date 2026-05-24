import AppKit
import SwiftUI

/// Full-pane child VC for the New Session (`.newSession`) selection.
/// `DetailRouterViewController` mounts this — and only this — for
/// `.newSession`; `.session(_)` / `.none` go to `ChatSessionViewController`.
///
/// **Why compose is its own VC.** Compose used to be a *mode* of
/// `ChatSessionViewController`, sharing its always-mounted
/// `composeOrBarHost`. That single `NSHostingView` had to morph between
/// a full-bleed configurator (compose) and a bottom-anchored bar (chat)
/// on every selection flip, which meant keeping an AppKit constraint
/// switch in sync with the SwiftUI body across runloop phases. The two
/// never landed in the same tick, so the full-bleed host lingered over
/// the transcript for a window after a fast switch and swallowed its
/// clicks / text selection. Giving compose its own VC deletes the shared
/// surface: this VC is full-bleed with nothing behind it (full-bleed
/// hit-testing harms nothing), and the chat VC's bar host is now *always*
/// bottom-anchored — it never has to be full-bleed, so there is no
/// non-bar footprint left to cover the transcript.
///
/// Wraps an `NSHostingController` (not a bare `NSHostingView`) so the
/// SwiftUI tree gets proper child-VC lifecycle plumbing — same rationale
/// as `ArchiveViewController`, including `sizingOptions = []` so the
/// card's fitting size doesn't bubble up through the split and collapse
/// the window.
@MainActor
final class ComposeSessionViewController: NSViewController {
    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let notifications: NotificationService
    let searchEngine: SyntaxHighlightEngine
    let searchBus: TranscriptSearchBus
    let inputDraftStore: InputDraftStore

    private var host: NSHostingController<AnyView>!

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
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Resolve the draft session id this card binds to up front and
        // hand it to the SwiftUI view as a plain value — NOT read
        // reactively from `model.draftSessionId`. On submit we flip
        // `selection` to `.session(_)` and nil out `draftSessionId`; a
        // reactive read would blank the configurator for the one tick
        // before the router swaps this VC out. Capturing the id keeps the
        // card stable until it's torn down.
        let draftSessionId = ensureDraftSession()

        let root = AnyView(
            ComposeSessionView(
                draftSessionId: draftSessionId,
                onSubmit: { [weak self] submission in
                    guard let self else { return }
                    submitSessionInput(
                        submission,
                        sessionId: draftSessionId,
                        sessionManager: self.sessionManager,
                        recentProjects: self.recentProjects,
                        model: self.model)
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
        )

        let host = NSHostingController(rootView: root)
        // See `ArchiveViewController` for the full rationale: a
        // fill-the-pane detail child must take whatever height the window
        // gives it via the 4-edge constraints below, never drive it. The
        // default `sizingOptions` would leak the compose card's fitting
        // size up through the split's `view.fittingSize` and resize the
        // window. `[]` severs that.
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.host = host
    }

    /// Lazy-allocate `model.draftSessionId` on first entry into New
    /// Session, seeding the draft's `cwd` / `originPath` so `session.cwd`
    /// is non-nil before `NewSessionConfigurator` and the input bar's
    /// completion context first read it. `useWorktree` / `sourceBranch`
    /// are left to `NewSessionConfigurator.applyProbeBindings(...)` to
    /// fill in off the git probe. Returns the resolved id. (Moved here
    /// verbatim from the pre-split `ChatSessionViewController`.)
    private func ensureDraftSession() -> String {
        if let existing = model.draftSessionId { return existing }
        let sid = UUID().uuidString.lowercased()
        model.draftSessionId = sid
        if let cwd = recentProjects.lastLaunchedPath,
            let draft = sessionManager.prepareDraftSession(sid).draft
        {
            draft.setCwd(cwd)
            draft.setOriginPath(cwd)
        }
        return sid
    }
}

// MARK: - SwiftUI body

/// The compose card itself: a `DotGridBackground` backdrop with the
/// centered `NewSessionConfigurator` (folder / branch / worktree pickers
/// + embedded input bar) on top. Full-bleed, no transcript behind it.
///
/// Takes `draftSessionId` as a plain value (see
/// `ComposeSessionViewController.viewDidLoad` for why it isn't read from
/// the model), resolves the draft `Session` through the environment
/// `SessionManager`, and binds the three configurator controls straight
/// to `session.draft.config`.
struct ComposeSessionView: View {
    let draftSessionId: String
    let onSubmit: (InputBarView2.Submission) -> Void
    let onResumeSession: (String) -> Void

    @Environment(SessionManager.self) private var manager

    var body: some View {
        let session = manager.prepareDraftSession(draftSessionId)
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
                        sessionId: draftSessionId,
                        draftKey: InputDraftStore.newSessionKey,
                        coordSpace: ChatSessionViewController.detailCoordSpace,
                        submitEnabled: session.cwd != nil,
                        onSubmit: onSubmit,
                        onAttachRect: { _ in },
                        onPillRect: { _ in }
                    )
                }
            )
            .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
            .padding(.vertical, ChatSessionViewController.detailVerticalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: ChatSessionViewController.detailCoordSpace)
        // Full-bleed: let the dot-grid backdrop extend under the unified
        // toolbar's safe-area inset instead of starting below it.
        .ignoresSafeArea()
    }

    private struct ComposeBindings {
        let folder: Binding<String?>
        let useWorktree: Binding<Bool>
        let sourceBranch: Binding<String?>
    }

    /// Bind the configurator's three controls straight to
    /// `session.draft.config`. There is no parallel storage on the
    /// selection model — the draft itself is the single source of truth,
    /// so the input bar's completion context and the submit path both
    /// observe the same values without a sync hop.
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
